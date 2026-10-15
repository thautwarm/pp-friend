use std::path::Path;

use ndarray::{Array2, Array3, ArrayView1, s};
use ort::session::{Session, builder::GraphOptimizationLevel};
use ort::tensor::Shape;
use ort::value::TensorRef;

use crate::{Error, Result};

const EMBEDDED_MODEL: &[u8] = include_bytes!("model_data/silero_vad_16k_op15.onnx.bin");
const INPUT_NAME: &str = "input";
const STATE_NAME: &str = "state";
const SAMPLE_RATE_NAME: &str = "sr";
const OUTPUT_NAME: &str = "output";
const NEW_STATE_NAME: &str = "new_state";
const LEGACY_NEW_STATE_NAME: &str = "stateN";

pub const SAMPLE_RATE: u32 = 16_000;
pub const FRAME_SIZE: usize = 512;
const CONTEXT_SIZE: usize = 64;
const STATE_LAYERS: usize = 2;
const STATE_HIDDEN: usize = 128;
const MODEL_INPUT_SIZE: usize = FRAME_SIZE + CONTEXT_SIZE;

pub(crate) struct SileroVadModel {
    session: Session,
    state: Array3<f32>,
    context: Array2<f32>,
    input: Array2<f32>,
    sample_rate_tensor: ndarray::Array0<i64>,
    last_batch_size: usize,
}

impl SileroVadModel {
    pub(crate) fn new() -> Result<Self> {
        Self::from_bytes(EMBEDDED_MODEL)
    }

    pub(crate) fn from_bytes(model_bytes: &[u8]) -> Result<Self> {
        let session = Session::builder()?
            .with_optimization_level(GraphOptimizationLevel::Level3)?
            .with_intra_threads(1)?
            .with_inter_threads(1)?
            .commit_from_memory(model_bytes)?;
        Self::from_session(session)
    }

    pub(crate) fn from_file<P: AsRef<Path>>(model_path: P) -> Result<Self> {
        let session = Session::builder()?
            .with_optimization_level(GraphOptimizationLevel::Level3)?
            .with_intra_threads(1)?
            .with_inter_threads(1)?
            .commit_from_file(model_path)?;
        Self::from_session(session)
    }

    fn from_session(session: Session) -> Result<Self> {
        Self::validate_model_signature(&session)?;
        Ok(Self {
            session,
            state: Array3::zeros((STATE_LAYERS, 1, STATE_HIDDEN)),
            context: Array2::zeros((1, CONTEXT_SIZE)),
            input: Array2::zeros((1, MODEL_INPUT_SIZE)),
            sample_rate_tensor: ndarray::arr0(SAMPLE_RATE as i64),
            last_batch_size: 1,
        })
    }

    fn validate_model_signature(session: &Session) -> Result<()> {
        let input_names: Vec<&str> = session.inputs().iter().map(|v| v.name()).collect();
        let output_names: Vec<&str> = session.outputs().iter().map(|v| v.name()).collect();

        for required in [INPUT_NAME, STATE_NAME, SAMPLE_RATE_NAME] {
            if !input_names.contains(&required) {
                return Err(Error::ModelLoad(format!(
                    "model is missing required input `{required}` (found: {input_names:?})"
                )));
            }
        }
        if !output_names.contains(&OUTPUT_NAME) {
            return Err(Error::ModelLoad(format!(
                "model is missing required output `{OUTPUT_NAME}` (found: {output_names:?})"
            )));
        }
        if !output_names
            .iter()
            .any(|name| *name == NEW_STATE_NAME || *name == LEGACY_NEW_STATE_NAME)
        {
            return Err(Error::ModelLoad(format!(
                "model is missing recurrent state output (`{NEW_STATE_NAME}` or `{LEGACY_NEW_STATE_NAME}`) (found: {output_names:?})"
            )));
        }

        Ok(())
    }

    pub(crate) fn reset_states(&mut self, batch_size: usize) {
        self.state = Array3::zeros((STATE_LAYERS, batch_size, STATE_HIDDEN));
        self.context = Array2::zeros((batch_size, CONTEXT_SIZE));
        if self.input.nrows() != batch_size {
            self.input = Array2::zeros((batch_size, MODEL_INPUT_SIZE));
        } else {
            self.input.fill(0.0);
        }
        self.last_batch_size = batch_size;
    }

    fn ensure_state_for(&mut self, batch_size: usize) {
        if self.last_batch_size != batch_size {
            self.reset_states(batch_size);
        }
    }

    fn validate_input(&self, frame: &ArrayView1<f32>) -> Result<()> {
        if frame.len() != FRAME_SIZE {
            return Err(Error::InvalidInput(format!(
                "each frame must contain exactly {FRAME_SIZE} samples"
            )));
        }
        Ok(())
    }

    fn probability_from_output(shape: &Shape, values: &[f32]) -> Result<f32> {
        match shape.len() {
            1 => {
                if shape[0] != 1 || values.len() != 1 {
                    return Err(Error::ModelLoad(format!(
                        "unexpected output shape: expected [1], got {:?}",
                        shape
                    )));
                }
                Ok(values[0])
            }
            2 => {
                if shape[0] != 1 || shape[1] <= 0 {
                    return Err(Error::ModelLoad(format!(
                        "unexpected output shape: expected [1, N>0], got {:?}",
                        shape
                    )));
                }
                values
                    .first()
                    .copied()
                    .ok_or_else(|| Error::ModelLoad("output tensor is unexpectedly empty".into()))
            }
            _ => Err(Error::ModelLoad(format!(
                "unexpected output rank: {}",
                shape.len()
            ))),
        }
    }

    fn new_state_from_output(
        shape: &Shape,
        values: &[f32],
        batch_size: usize,
    ) -> Result<Array3<f32>> {
        let expected = [
            STATE_LAYERS as i64,
            i64::try_from(batch_size)
                .map_err(|_| Error::ModelLoad("batch_size does not fit i64".into()))?,
            STATE_HIDDEN as i64,
        ];
        if shape.len() != expected.len()
            || shape[0] != expected[0]
            || shape[1] != expected[1]
            || shape[2] != expected[2]
        {
            return Err(Error::ModelLoad(format!(
                "unexpected recurrent state shape: {:?}, expected {:?}",
                shape, expected
            )));
        }
        let expected_elements = STATE_LAYERS * batch_size * STATE_HIDDEN;
        if values.len() != expected_elements {
            return Err(Error::ModelLoad(format!(
                "unexpected recurrent state element count: {}, expected {}",
                values.len(),
                expected_elements
            )));
        }
        Array3::from_shape_vec((STATE_LAYERS, batch_size, STATE_HIDDEN), values.to_vec())
            .map_err(|err| Error::ModelLoad(format!("invalid recurrent state layout: {err}")))
    }

    pub(crate) fn process_frame(&mut self, frame: &ArrayView1<f32>) -> Result<f32> {
        self.validate_input(frame)?;
        self.ensure_state_for(1);

        self.input
            .slice_mut(s![.., ..CONTEXT_SIZE])
            .assign(&self.context);
        self.input.slice_mut(s![0, CONTEXT_SIZE..]).assign(frame);

        let (probability, new_state) = {
            let outputs = self.session.run(ort::inputs! {
                INPUT_NAME => TensorRef::from_array_view(self.input.view())?,
                STATE_NAME => TensorRef::from_array_view(self.state.view())?,
                SAMPLE_RATE_NAME => TensorRef::from_array_view(self.sample_rate_tensor.view())?,
            })?;

            let (probability_shape, probability_values) = outputs
                .get(OUTPUT_NAME)
                .ok_or_else(|| Error::ModelLoad("missing `output` tensor".into()))?
                .try_extract_tensor::<f32>()?;
            let probability = Self::probability_from_output(probability_shape, probability_values)?;

            let (state_shape, state_values) = outputs
                .get(NEW_STATE_NAME)
                .or_else(|| outputs.get(LEGACY_NEW_STATE_NAME))
                .ok_or_else(|| Error::ModelLoad("missing recurrent state tensor".into()))?
                .try_extract_tensor::<f32>()?;
            let new_state = Self::new_state_from_output(state_shape, state_values, 1)?;
            (probability, new_state)
        };

        self.state.assign(&new_state);
        self.context
            .row_mut(0)
            .assign(&frame.slice(s![FRAME_SIZE - CONTEXT_SIZE..]));

        self.last_batch_size = 1;
        Ok(probability)
    }
}
