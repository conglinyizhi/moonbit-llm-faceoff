///|
/// 基准结果的数据视图层：把 bench 导出的 data.json 解析成类型，并提供渲染组件。
///
/// 同时被两个前端复用：
///   - cmd/ssg   静态导出（SSR）
///   - cmd/app   交互页（js，Rabbita TEA）
/// 所以这个包必须与 target 无关，只做 JSON + HTML，不碰文件系统或网络。
