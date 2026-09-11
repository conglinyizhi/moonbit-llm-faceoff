///|
/// 两个答案之间的差异。
///
/// 放在 shared 里的理由和别的渲染件一样：交互页与静态报告看的是同一份结果，
/// 差异的算法不该有两份实现——两份就意味着「同一个问题在两个地方结论不同」。

///|
/// 差异里的一段：`same` 两边一样，`del` 只有左边有，`ins` 只有右边有。
pub(all) struct DiffPart {
  kind : String
  mut text : String
} derive(Eq)

///|
pub extend DiffPart with Eq::{equal, not_equal}

///|
/// 差异里的一行。
///
/// `kind` 是 same / del / ins / change-del / change-ins。`change-*` 是「同一行
/// 改了几个字」——两行配成一对，`parts` 里只保留属于这一侧的那半，行内就能把
/// 改动的几个字标出来。中文长回答里最常见的差异就是这种：整行只差一个标点，
/// 按整行标红等于什么都没说。
pub(all) struct DiffLine {
  kind : String
  text : String
  parts : Array[DiffPart]?
} derive(Eq)

///|
pub extend DiffLine with Eq::{equal, not_equal}

///|
/// 字符级差异。先剥掉公共前后缀，只对中间那段做 LCS——两个模型答同一道题时，
/// 开头结尾往往是一样的，剥完剩下的通常很短。中间太长就整段标成「变了」，
/// 不为一个页面把 O(n·m) 的表撑到几十兆。
pub fn diff_chars(left : String, right : String) -> Array[DiffPart] {
  let a = left
  let b = right
  let mut prefix = 0
  let limit = @cmp.minimum(a.length(), b.length())
  while prefix < limit && a[prefix] == b[prefix] {
    prefix = prefix + 1
  }
  let mut suffix = 0
  while suffix < limit - prefix &&
        a[a.length() - 1 - suffix] == b[b.length() - 1 - suffix] {
    suffix = suffix + 1
  }
  let parts : Array[DiffPart] = []
  if prefix > 0 {
    parts.push({ kind: "same", text: a[:prefix].to_owned(), })
  }
  let mid_a = a[prefix:a.length() - suffix].to_owned()
  let mid_b = b[prefix:b.length() - suffix].to_owned()
  if mid_a != "" || mid_b != "" {
    if mid_a.length() * mid_b.length() > 200000 {
      // 两边几乎没有公共部分：直接说清楚，别假装算过
      if mid_a != "" {
        parts.push({ kind: "del", text: mid_a, })
      }
      if mid_b != "" {
        parts.push({ kind: "ins", text: mid_b, })
      }
    } else {
      for part in lcs_blocks(mid_a, mid_b) {
        parts.push(part)
      }
    }
  }
  if suffix > 0 {
    parts.push({ kind: "same", text: a[a.length() - suffix:].to_owned(), })
  }
  parts
}

///|
/// 差异里的一段，作用在字符串上：整段同类只出现一次，所以按**区间**从原串上
/// 切下来，而不是一个字符一个字符往上拼。
///
/// 这条不是风格问题：`Char::to_string()` 给的是码点数字（`'a'` 拼出来是
/// `"97"`），逐字拼出来的差异页会是 "104101108108111" 这种东西——中文更糊。
fn push_run(
  parts : Array[DiffPart],
  kind : Int,
  a : String,
  b : String,
  from_a : Int,
  to_a : Int,
  from_b : Int,
  to_b : Int,
) -> Unit {
  if kind == 3 || (to_a <= from_a && to_b <= from_b) {
    return
  }
  let label = match kind {
    0 => "same"
    1 => "del"
    _ => "ins"
  }
  let text = if kind == 2 {
    b[from_b:to_b].to_owned()
  } else {
    a[from_a:to_a].to_owned()
  }
  push_part(parts, label, text)
}

///|
/// 按行的差异，给长回答用。
///
/// 字符级差异在「两个模型各写了一段话」上几乎全是红的：公共子序列短，整段都
/// 算「变了」，读的人得不到任何定位。真正要回答的是「从哪一行开始分岔、分岔
/// 成什么样」，所以这里先按行对齐，相同的行只出现一次，成对的行再在同一行内
/// 做字符级高亮。
pub fn diff_lines(left : String, right : String) -> Array[DiffLine] {
  let a = split_lines(left)
  let b = split_lines(right)
  let ops = lcs_line_ops(a, b)
  let out : Array[DiffLine] = []
  let mut i = 0
  while i < ops.length() {
    if ops[i].0 == 0 {
      out.push({ kind: "same", text: a[ops[i].1], parts: None, })
      i = i + 1
      continue
    }
    // 一整块「左边有、右边也有（但不一样）」：先把这一块里的删除行和新增行
    // 各自收齐，再按位置配对。LCS 会在块内交错给出删和增，逐条处理就会把
    // 不相干的行配到一起。
    let dels : Array[String] = []
    let inss : Array[String] = []
    while i < ops.length() && ops[i].0 != 0 {
      if ops[i].0 == 1 {
        dels.push(a[ops[i].1])
      } else {
        inss.push(b[ops[i].2])
      }
      i = i + 1
    }
    let paired = if dels.length() < inss.length() {
      dels.length()
    } else {
      inss.length()
    }
    for k = 0; k < paired; k = k + 1 {
      let parts = diff_chars(dels[k], inss[k])
      out.push({
        kind: "change-del",
        text: dels[k],
        parts: Some(parts.filter(fn(part) { part.kind != "ins" })),
      })
      out.push({
        kind: "change-ins",
        text: inss[k],
        parts: Some(parts.filter(fn(part) { part.kind != "del" })),
      })
    }
    for k = paired; k < dels.length(); k = k + 1 {
      out.push({ kind: "del", text: dels[k], parts: None, })
    }
    for k = paired; k < inss.length(); k = k + 1 {
      out.push({ kind: "ins", text: inss[k], parts: None, })
    }
  }
  out
}

///|
/// 拆成行，去掉末尾那个空行造成的假差异。
fn split_lines(text : String) -> Array[String] {
  let lines : Array[String] = []
  for line in text.split("\n") {
    lines.push(line.to_owned())
  }
  while lines.length() > 0 &&
        lines[lines.length() - 1].trim(chars=" \t\r") == "" {
    let _ = lines.pop()
  }
  lines
}

///|
/// 行级 LCS 的结果，每一项是 `(操作, a 的下标, b 的下标)`：0 = 相同，
/// 1 = 只出现在 a，2 = 只出现在 b。
///
/// 和字符级那份同一个思路（从后往前填表，再顺着走一遍），只是单位从字符换成行。
fn lcs_line_ops(a : Array[String], b : Array[String]) -> Array[(Int, Int, Int)] {
  let n = a.length()
  let m = b.length()
  let rows : Array[Array[Int]] = []
  for i = 0; i <= n; i = i + 1 {
    rows.push(Array::make(m + 1, 0))
  }
  for i = n - 1; i >= 0; i = i - 1 {
    for j = m - 1; j >= 0; j = j - 1 {
      rows[i][j] = if a[i] == b[j] {
        rows[i + 1][j + 1] + 1
      } else {
        @cmp.maximum(rows[i + 1][j], rows[i][j + 1])
      }
    }
  }
  let ops : Array[(Int, Int, Int)] = []
  let mut i = 0
  let mut j = 0
  while i < n && j < m {
    if a[i] == b[j] {
      ops.push((0, i, j))
      i = i + 1
      j = j + 1
    } else if rows[i + 1][j] >= rows[i][j + 1] {
      ops.push((1, i, j))
      i = i + 1
    } else {
      ops.push((2, i, j))
      j = j + 1
    }
  }
  while i < n {
    ops.push((1, i, j))
    i = i + 1
  }
  while j < m {
    ops.push((2, i, j))
    j = j + 1
  }
  ops
}

///|
/// 把连续相同的行压成「… N 行相同 …」。长回答里大部分行是一样的，逐行渲染
/// 出来的差异页和原文一样长，等于没比。
pub fn collapse_same(lines : Array[DiffLine], keep : Int) -> Array[DiffLine] {
  let out : Array[DiffLine] = []
  let mut i = 0
  while i < lines.length() {
    if lines[i].kind != "same" {
      out.push(lines[i])
      i = i + 1
      continue
    }
    let mut run = 0
    while i + run < lines.length() && lines[i + run].kind == "same" {
      run = run + 1
    }
    if run <= keep * 2 {
      for k = 0; k < run; k = k + 1 {
        out.push(lines[i + k])
      }
    } else {
      for k = 0; k < keep; k = k + 1 {
        out.push(lines[i + k])
      }
      out.push({
        kind: "gap",
        text: "… 中间 \{run - keep * 2} 行两边相同 …",
        parts: None,
      })
      for k = run - keep; k < run; k = k + 1 {
        out.push(lines[i + k])
      }
    }
    i = i + run
  }
  out
}

///|
fn lcs_blocks(a : String, b : String) -> Array[DiffPart] {
  let n = a.length()
  let m = b.length()
  // dp[i][j]：a[i:] 与 b[j:] 的最长公共子序列长度
  let rows : Array[Array[Int]] = []
  for i = 0; i <= n; i = i + 1 {
    rows.push(Array::make(m + 1, 0))
  }
  for i = n - 1; i >= 0; i = i - 1 {
    for j = m - 1; j >= 0; j = j - 1 {
      rows[i][j] = if a[i] == b[j] {
        rows[i + 1][j + 1] + 1
      } else {
        @cmp.maximum(rows[i + 1][j], rows[i][j + 1])
      }
    }
  }
  let parts : Array[DiffPart] = []
  let mut i = 0
  let mut j = 0
  // 3 = 还没有段：0 相同 / 1 只在左边 / 2 只在右边
  let mut kind = 3
  let mut from_a = 0
  let mut from_b = 0
  while i < n && j < m {
    let next = if a[i] == b[j] {
      0
    } else if rows[i + 1][j] >= rows[i][j + 1] {
      1
    } else {
      2
    }
    if next != kind {
      push_run(parts, kind, a, b, from_a, i, from_b, j)
      kind = next
      from_a = i
      from_b = j
    }
    if next == 0 {
      i = i + 1
      j = j + 1
    } else if next == 1 {
      i = i + 1
    } else {
      j = j + 1
    }
  }
  // 主循环收尾：先结掉手上这一段，剩下的单边各自成段（同类会由 push_part 并起来）
  push_run(parts, kind, a, b, from_a, i, from_b, j)
  push_run(parts, 1, a, b, i, n, j, m)
  push_run(parts, 2, a, b, i, n, j, m)
  parts
}

///|
/// 相邻的同类片段合并起来：一个字符一段的话，DOM 里会有几万个 span。
fn push_part(parts : Array[DiffPart], kind : String, text : String) -> Unit {
  match parts {
    [.., last] =>
      if last.kind == kind {
        last.text = last.text + text
        return
      }
    [] => ()
  }
  parts.push({ kind, text, })
}
