///|
/// Decodes and validates a TypeSafe `/v1/systemone` response.
///
/// Every field a decision depends on is validated before any answer in the
/// batch is accepted: a partially valid batch is rejected outright rather than
/// producing a mix of real and invented verdicts.
pub fn decode_response(
  text : String,
  question_ids : Array[String],
) -> JevResponse raise {
  let root = parse_strict(text, "API response")
  let obj = expect_object(root, "API response")
  let model = expect_string(field(obj, "model", "API response"), "response model")
  if model.trim(chars=" \t\r\n").is_empty() {
    raise GateError("API response has an empty model field.")
  }
  let usage = expect_object(field(obj, "usage", "API response"), "response usage")
  for key, value in usage {
    match value {
      Json::Number(v, ..) =>
        if v.is_nan() || v.is_inf() || v < 0.0 || v.to_int().to_double() != v {
          raise GateError(
            "API response usage field '\{sanitize_line(key)}' is not a nonnegative integer.",
          )
        }
      _ => ()
    }
  }
  let answers_obj = expect_object(
    field(obj, "answers", "API response"),
    "response answers",
  )
  if answers_obj.length() != question_ids.length() {
    raise GateError(
      "API response returned \{answers_obj.length()} answers for \{question_ids.length()} questions.",
    )
  }
  let answers : Map[String, ChoiceAnswer] = Map([])
  for id in question_ids {
    match answers_obj.get(id) {
      None =>
        raise GateError("API response is missing an answer for rule '\{sanitize_line(id)}'.")
      Some(value) => answers[id] = decode_choice_answer(value, id)
    }
  }
  { model, answers }
}

///|
fn decode_choice_answer(value : Json, id : String) -> ChoiceAnswer raise {
  let show = sanitize_line(id)
  let obj = expect_object(value, "answer for rule '\{show}'")
  let kind = expect_string(field(obj, "type", "answer '\{show}'"), "answer type")
  if kind != "choice" {
    raise GateError(
      "Answer for rule '\{show}' has type '\{sanitize_line(kind)}', expected 'choice'.",
    )
  }
  let choice = expect_string(field(obj, "choice", "answer '\{show}'"), "answer choice")
  if choice != label_violation &&
    choice != label_compliant &&
    choice != label_insufficient {
    raise GateError(
      "Answer for rule '\{show}' has unknown label '\{sanitize_line(choice)}'.",
    )
  }
  let probs = expect_object(
    field(obj, "probabilities", "answer '\{show}'"),
    "answer '\{show}' probabilities",
  )
  reject_unknown(
    probs,
    [label_violation, label_compliant, label_insufficient],
    "answer '\{show}' probabilities",
  )
  if probs.length() != 3 {
    raise GateError(
      "Answer for rule '\{show}' must carry exactly three probabilities.",
    )
  }
  let read = fn(label : String) -> Double raise {
    let v = expect_number(field(probs, label, "answer '\{show}' probabilities"), "probability")
    if v.is_nan() || v.is_inf() || v < 0.0 || v > 1.0 {
      raise GateError(
        "Answer for rule '\{show}' has an out-of-range probability for '\{label}'.",
      )
    }
    v
  }
  let p_violation = read(label_violation)
  let p_compliant = read(label_compliant)
  let p_insufficient = read(label_insufficient)
  let total = p_violation + p_compliant + p_insufficient
  if (total - 1.0).abs() > 0.001 {
    raise GateError(
      "Answer for rule '\{show}' has probabilities that do not sum to 1.",
    )
  }
  let confidence = expect_number(
    field(obj, "confidence", "answer '\{show}'"),
    "answer confidence",
  )
  if confidence.is_nan() || confidence.is_inf() || confidence < 0.0 || confidence > 1.0 {
    raise GateError("Answer for rule '\{show}' has an out-of-range confidence.")
  }
  let answer = { choice, p_violation, p_compliant, p_insufficient, confidence }
  let chosen = answer.probability_of(choice)
  if chosen < p_violation || chosen < p_compliant || chosen < p_insufficient {
    raise GateError(
      "Answer for rule '\{show}' selected '\{sanitize_line(choice)}' without a maximal probability.",
    )
  }
  answer
}
