///|
/// 人工标注这一块：拉取、存、改，以及答案块下面那个编辑器。
///
/// 和工作台其他面板同一个理由分出来：main.mbt 是表单与结果，这里是「人对结果的
/// 判断」——数据属于运行目录（`annotations.jsonl`），跟这次运行一起生死。

///|
/// 拉这次运行的请求上下文（参数 + 每条用例生效的 system/prompt）。
///
/// 单开一个接口而不是塞进状态响应：状态在运行中是 250ms 拉一次的，而这份文档
/// 只有点开对话框那一刻需要一次。
fn fetch_context(id : String, emit : @cmd.Emit[Msg]) -> @cmd.Cmd {
  @http.get("/api/runs/" + id + "/context").expect_json(
    // 把 id 带回去：回来的那份缓存要记住它属于哪次运行
    emit.map(fn(result) { ContextLoaded(id, result) }),
  )
}

///|
fn fetch_annotations(id : String, emit : @cmd.Emit[Msg]) -> @cmd.Cmd {
  @http.get("/api/runs/" + id + "/annotations").expect_json(
    emit.map(fn(result) { AnnotationsLoaded(id, result) }),
  )
}

///|
fn save_annotations(
  id : String,
  annotations : Array[@shared.Annotation],
  emit : @cmd.Emit[Msg],
) -> @cmd.Cmd {
  @http.put("/api/runs/" + id + "/annotations")
  .with_json(annotations_json(annotations))
  .expect_json(emit.map(fn(result) { AnnotationsSaved(result) }))
}

///|
fn annotations_json(annotations : Array[@shared.Annotation]) -> Json {
  Json::object({
    "annotations": Json::array(
      annotations.map(fn(entry) {
        Json::object({
          "case_id": Json::string(entry.case_id),
          "model": Json::string(entry.model),
          "verdict": Json::string(entry.verdict),
          "note": Json::string(entry.note),
        })
      }),
    ),
  })
}

///|
/// 改一条标注。判定点一下就存、备注按按钮才存，所以这里必须能只动一半；
/// 两条都空的条目直接删掉——「判过又清了、备注也空」不该在文件里留一行。
fn set_annotation(
  annotations : Array[@shared.Annotation],
  case_id : String,
  answer_model : String,
  verdict : String,
  note : String?,
) -> Array[@shared.Annotation] {
  let out : Array[@shared.Annotation] = []
  let mut found = false
  for entry in annotations {
    if entry.case_id == case_id && entry.model == answer_model {
      found = true
      let next_verdict = if verdict != "" { verdict } else { entry.verdict }
      let next_note = match note {
        Some(text) => text
        None => entry.note
      }
      if next_verdict != "" || next_note != "" {
        out.push({ ..entry, verdict: next_verdict, note: next_note, })
      }
    } else {
      out.push(entry)
    }
  }
  if !found {
    let next_note = match note {
      Some(text) => text
      None => ""
    }
    if verdict != "" || next_note != "" {
      out.push({ case_id, model: answer_model, verdict, note: next_note, })
    }
  }
  out
}

///|
fn annotation_of(
  annotations : Array[@shared.Annotation],
  case_id : String,
  answer_model : String,
) -> @shared.Annotation? {
  match
    annotations.filter(fn(entry) {
      entry.case_id == case_id && entry.model == answer_model
    }) {
    [first, ..] => Some(first)
    [] => None
  }
}

///|
/// 结果区里每条答案下面那个编辑器。
///
/// 备注框拿到的是「正在编辑的那条」的草稿；其他条显示已存的备注——不然切换
/// 答案时草稿会串到别人身上。
fn annotation_editor_for(
  model : AppModel,
  case_id : String,
  answer_model : String,
  emit : @cmd.Emit[Msg],
) -> @html.Html {
  let entry = annotation_of(model.annotations, case_id, answer_model)
  let key = case_id + "\u{0}" + answer_model
  let note = if model.note_key == Some(key) {
    model.note_draft
  } else {
    match entry {
      Some(entry) => entry.note
      None => ""
    }
  }
  @shared.annotation_editor(
    entry,
    note,
    emit(SetVerdict(case_id, answer_model, "pass")),
    emit(SetVerdict(case_id, answer_model, "fail")),
    emit(SetVerdict(case_id, answer_model, "unsure")),
    emit(SetVerdict(case_id, answer_model, "")),
    emit.map(fn(text) { NoteChanged(case_id, answer_model, text) }),
    emit(SaveNote(case_id)),
  )
}
