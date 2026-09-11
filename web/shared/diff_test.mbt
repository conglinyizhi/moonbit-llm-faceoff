///|
/// 拼接一段差异里的文字：用来断言「差异页上真的是这些字符」。
///
/// 之所以按内容断言而不是「有没有渲染出 diff-block」：字符级差异曾经把每个
/// 字符用 `Char::to_string()` 拼回去，而它给的是**码点数字**，于是差异页上
/// 是 "229142265" 这种东西。元素数量、元素有没有，全都正常。
fn text_of(parts : Array[DiffPart]) -> String {
  let out = StringBuilder()
  for part in parts {
    out.write_string(part.text)
  }
  out.to_string()
}

///|
test "char diff keeps the characters, not their code points" {
  let parts = diff_chars(
    "甲板风是把航母吹偏的风", "甲板风是把航母推偏的风",
  )
  // same + del 必须正好还原左边，same + ins 正好还原右边——差异页两边都靠它
  let left = StringBuilder()
  let right = StringBuilder()
  for part in parts {
    if part.kind != "ins" {
      left.write_string(part.text)
    }
    if part.kind != "del" {
      right.write_string(part.text)
    }
  }
  assert_eq(left.to_string(), "甲板风是把航母吹偏的风")
  assert_eq(right.to_string(), "甲板风是把航母推偏的风")
  assert_true(text_of(parts).contains("推"))
  assert_false(text_of(parts).contains("25512"))
}

///|
test "line diff pairs a slightly edited line instead of deleting and adding it" {
  let left = "第一行\n第二行,带个半角逗号\n第三行"
  let right = "第一行\n第二行，带个全角逗号\n第三行"
  let lines = diff_lines(left, right)
  let kinds = StringBuilder()
  for line in lines {
    kinds.write_string(line.kind)
    kinds.write_string(",")
  }
  assert_eq(kinds.to_string(), "same,change-del,change-ins,same,")
  // 行内高亮只保留属于这一侧的那半，拼起来还得是整行
  let del_line = lines[1]
  let ins_line = lines[2]
  let del_text = match del_line.parts {
    Some(parts) => text_of(parts.filter(fn(part) { part.kind != "ins" }))
    None => del_line.text
  }
  assert_eq(del_text, "第二行,带个半角逗号")
  let ins_text = match ins_line.parts {
    Some(parts) => text_of(parts.filter(fn(part) { part.kind != "del" }))
    None => ins_line.text
  }
  assert_eq(ins_text, "第二行，带个全角逗号")
}

///|
test "identical answers produce no differences at all" {
  let text = "一行一样的话\n第二行也一样"
  let lines = diff_lines(text, text)
  for line in lines {
    assert_eq(line.kind, "same")
  }
  // 末尾空行的差异是假的：两边都一样不该报「有一行不同」
  assert_eq(diff_lines("甲\n\n", "甲").length(), 1)
}

///|
test "long identical stretches collapse into one gap line" {
  let lines : Array[DiffLine] = []
  for i = 0; i < 40; i = i + 1 {
    lines.push({ kind: "same", text: "第 \{i} 行", parts: None, })
  }
  let collapsed = collapse_same(lines, 2)
  assert_eq(collapsed.length(), 5)
  assert_eq(collapsed[2].kind, "gap")
  assert_true(collapsed[2].text.contains("36"))
}
