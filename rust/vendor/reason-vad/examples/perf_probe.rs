use std::time::Instant;

use reason_vad::{ReasonVad, SAMPLE_RATE_HZ};

fn main() {
    let audio_seconds = 300usize;
    let samples = vec![0.0_f32; audio_seconds * SAMPLE_RATE_HZ as usize];

    let mut vad = ReasonVad::new().expect("VAD initialization should succeed");
    let start = Instant::now();
    let _ = vad.process_pcm(&samples).expect("streaming should succeed");
    let _ = vad.finish().expect("finish should succeed");
    let elapsed = start.elapsed().as_secs_f64();

    let audio_duration = samples.len() as f64 / SAMPLE_RATE_HZ as f64;
    let rtf = elapsed / audio_duration;
    let x_realtime = audio_duration / elapsed;

    println!("audio_seconds={audio_duration:.2}");
    println!("elapsed_seconds={elapsed:.4}");
    println!("rtf={rtf:.6}");
    println!("speed_x_realtime={x_realtime:.2}");
}
