///|
/// 侧栏历史只铺这么多条：再长就把整页推下去，而且它不是主角
let history_panel_limit : Int = 10

///|
/// 弹窗第一步铺多少
let history_first_page : Int = 50

///|
/// 之后每次「加载更多」加多少
let history_more_page : Int = 30

///|
/// 「正在看的那条」在弹窗里落在第几格。
///
/// 取 8 不是随手挑的：一整屏大约能放十六七条，把目标放在第 8 格，它上下就各有
/// 七八条——对比两次运行、或者看「跑完这条之后又跑了哪些」时，需要看到的正是
/// 目标前后的邻居，而不是让目标孤零零贴在顶部
let history_slot : Int = 8

///|
/// 把弹窗列表滚到「让第 index 条落在第 slot 格」的位置。
///
/// 这一步放在 DOM 上做（不经过 AppModel）：它是纯视觉的一次性定位，跟数据无关；
/// 走状态机反而要为了「滚动位置」多存一份状态、还要处理它和渲染的先后
///
/// 推迟一拍再滚：调用它的地方是 update，那时弹窗还没渲染出来，
/// 立刻查 .history-dialog-list 只会拿到 null。
///
/// 用 setTimeout 而不是 requestAnimationFrame：无头浏览器（没有合成器）里 rAF
/// 不保证回调，实测就是它导致滚动没发生
extern "js" fn pin_history_slot(index : Int, slot : Int) -> Unit =
  #|(index, slot) => {
  #|  const pin = (tries) => {
  #|    const list = document.querySelector(".history-dialog-list")
  #|    if (!list) {
  #|      // 弹窗还没渲染出来。等它一下——这里不能假设 update 之后 DOM 立刻就有了
  #|      if (tries > 0) setTimeout(() => pin(tries - 1), 50)
  #|      return
  #|    }
  #|    const item = list.children[index]
  #|    if (!item) return
  #|    const rowHeight = item.offsetHeight + 8
  #|    // 用 rect 差算「item 相对列表内容顶部」的位置：offsetTop 是相对最近的
  #|    // 定位祖先，而列表本身没有 position，直接用会拿到别的祖先的坐标
  #|    const top = item.getBoundingClientRect().top - list.getBoundingClientRect().top + list.scrollTop
  #|    list.scrollTop = Math.max(0, top - rowHeight * (slot - 1))
  #|  }
  #|  setTimeout(() => pin(20), 0)
  #|}

///|
/// 历史记录的完整视图：侧栏放不下的那些、以及分页。
///
/// 数据没有额外的接口——/api/runs 一次把全部历史给过来，所以「分页」是在本地
/// 切片（第一步 50、之后每次 30）。切片的用处是把 DOM 控制在一个规模内：几百条
/// 一次性铺出来，打开弹窗会明显卡一下。真到几千条的量级才需要服务端分页
fn history_dialog(model : AppModel, emit : @cmd.Emit[Msg]) -> @html.Html {
  if !model.history_open {
    return @html.fragment([])
  }
  let runs = match model.runs {
    Some(runs) => runs
    None => []
  }
  let shown = if model.history_shown > runs.length() {
    runs.length()
  } else {
    model.history_shown
  }
  // 只铺已经显示的那一段：切片而不是把全部丢给 vdom
  let items : Array[@html.Html] = []
  for i = 0; i < shown; i = i + 1 {
    // 侧栏只铺前 10 条。弹窗里在这一段之后插一张卡片当界线：从这里往下都是
    // 侧栏没展示的。条数不够（没有藏着的）就不插，免得卡片自己指着空白
    if i == history_panel_limit && runs.length() > history_panel_limit {
      items.push(
        el("div", "history-dialog-divider", [
          txt("从这里往下是侧边栏没有展示的历史记录"),
        ]),
      )
    }
    items.push(run_item(model, runs[i], emit))
  }
  let remaining = runs.length() - shown
  @shared.modal(
    "运行记录",
    "共 \{runs.length()} 次，已显示 \{shown} 次",
    el("div", "history-dialog-body", [
      el("div", "history-dialog-list", items),
      if remaining > 0 {
        el("div", "history-dialog-more", [
          @html.button(class="ghost", on_click=emit(Msg::LoadMoreHistory), [
            txt(
              "再加载 \{if remaining > history_more_page { history_more_page } else { remaining }} 条（还剩 \{remaining}）",
            ),
          ]),
        ])
      } else {
        el("div", "history-dialog-more muted", [txt("到底了")])
      },
    ]),
    emit(Msg::CloseHistory),
  )
}
