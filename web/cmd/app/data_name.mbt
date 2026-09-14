///|
/// data-name 注入：把「这个元素是干什么的」写成一个稳定属性，供人和 AI 定位。
///
/// 为什么是运行时注入而不是直接写在模板里：Rabbita 没有公开的「任意属性」入口。
/// `Attrs::attribute` 与 Attrs 的字段都是包内私有的，`el(tag, class, children)`
/// 也只收类名——想给元素挂 `data-name`，要么改 Rabbita 上游，要么在 DOM 上补。
/// 这里选后者：这段逻辑只影响定位，不参与任何渲染与状态。
///
/// 类名在这个仓库里是手写的、不会被工具链混淆，所以「选择器 → 名字」这张表是稳定的。
/// 列表项与同类控件共用同一个名字（`run-history-item`、`case-checkbox`…），
/// 与 skill 的建议一致：名字表达语义角色，不带位置与序号。
///
/// 名字一律 kebab-case，取自元素在页面上的角色：
///   gateway-url-input     网关地址输入框
///   start-run-btn         开始评测
///   run-history-item      历史记录里的一条
///   ...
extern "js" fn deploy_data_names() -> Unit =
  #|() => {
  #|  const NAMES = [
  #|    [".site-logo", "site-logo"],
  #|    [".site-meta", "site-meta"],
  #|    [".hero h1", "page-title"],
  #|    [".hero > p", "page-lead"],
  #|    ["#base-url", "gateway-url-input"],
  #|    ["#api-key", "api-key-input"],
  #|    ["#extra-models", "extra-models-input"],
  #|    [".cot-box", "reasoning-box"],
  #|    [".cot-row .check input", "reasoning-toggle"],
  #|    [".cot-box .cot-all button", "reasoning-select-all-btn"],
  #|    [".picker-core", "system-prompt-field"],
  #|    ["#system", "system-prompt-input"],
  #|    ["#system-override", "system-override-toggle"],
  #|    [".case-panel", "case-panel"],
  #|    [".panel-tabs button", "case-panel-tab"],
  #|    ["#case-set", "case-set-select"],
  #|    ["#new-set-name", "new-set-name-input"],
  #|    [".case-panel .check input", "case-checkbox"],
  #|    [".case-panel .picker-all button", "case-select-btn"],
  #|    [".case-panel .picker-more button", "case-expand-btn"],
  #|    [".import-row button", "import-file-btn"],
  #|    [".preset-panel", "preset-panel"],
  #|    [".preset", "preset-item"],
  #|    [".preset .link-btn:not(.danger)", "preset-apply-btn"],
  #|    [".preset .link-btn.danger", "preset-delete-btn"],
  #|    [".preset-actions .set-name", "preset-name-input"],
  #|    [".preset-actions button", "preset-save-btn"],
  #|    ["#repeats", "repeats-input"],
  #|    ["#max-tokens", "max-tokens-input"],
  #|    ["#temperature", "temperature-input"],
  #|    ["#pace-ms", "pace-ms-input"],
  #|    ["#retry", "retry-input"],
  #|    [".parallel-option", "parallel-option"],
  #|    [".parallel-option input", "parallel-radio"],
  #|    [".confirm-box", "confirm-box"],
  #|    [".confirm-row", "confirm-row"],
  #|    [".confirm-row button", "confirm-adjust-btn"],
  #|    [".issues.errors", "config-errors"],
  #|    [".issues.warnings", "config-warnings"],
  #|    ["button.primary", "start-run-btn"],
  #|    [".actions .hint", "request-cost-hint"],
  #|    [".progress-card", "progress-card"],
  #|    [".live-row", "live-row"],
  #|    [".results-switch button", "results-view-btn"],
  #|    [".answer-col", "answer-column"],
  #|    [".export-row button, .export-row a", "export-btn"],
  #|    [".history", "run-history"],
  #|    [".history-item:not(.history-more)", "run-history-item"],
  #|    [".history-item .link-btn", "run-history-action-btn"],
  #|    [".history-more button", "run-history-more-btn"],
  #|    [".modal", "modal"],
  #|    [".history-dialog-list", "run-history-list"],
  #|    [".history-dialog-more button", "run-history-load-more-btn"],
  #|    [".context-btn", "open-context-btn"],
  #|    [".annotation-editor", "annotation-editor"],
  #|    [".annotation-editor button", "verdict-btn"],
  #|    [".annotation-editor textarea", "note-input"],
  #|    [".site-footer", "site-footer"],
  #|  ]
  #|  const apply = (root) => {
  #|    for (const [selector, name] of NAMES) {
  #|      // 节点自己也可能是目标：vdom 重渲染时被换掉的往往就是容器本身，
  #|      // 只查后代的话，那些容器永远挂不上名字
  #|      if (root.nodeType === 1 && root.matches(selector) && root.dataset.name !== name) {
  #|        root.dataset.name = name
  #|      }
  #|      for (const el of root.querySelectorAll(selector)) {
  #|        // 已经有了就不动：MutationObserver 会看到自己写的属性，
  #|        // 不判一下就会自己触发自己
  #|        if (el.dataset.name !== name) el.dataset.name = name
  #|      }
  #|    }
  #|  }
  #|  const start = () => {
  #|    apply(document)
  #|    // 页面是 vdom 驱动的，重渲染会换掉一批节点：跟上新增的子树
  #|    new MutationObserver((records) => {
  #|      for (const record of records) {
  #|        for (const node of record.addedNodes) {
  #|          if (node.nodeType === 1) apply(node)
  #|        }
  #|      }
  #|    }).observe(document.body, { childList: true, subtree: true })
  #|  }
  #|  if (document.body) start()
  #|  else document.addEventListener("DOMContentLoaded", start)
  #|}
