/* 主页引导：挂语言切换、应用字典。 */
(() => {
  "use strict";
  const I = window.PP_I18N;
  I.mountSwitcher(document.getElementById("langSwitch"));
  I.apply();
})();
