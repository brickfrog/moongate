///|
/// Rule severity. Only a `Blocking` violation can fail CI.
pub(all) enum Severity {
  Advisory
  Blocking
} derive(Eq, Debug)

///|
pub fn Severity::label(self : Severity) -> String {
  match self {
    Advisory => "advisory"
    Blocking => "blocking"
  }
}

///|
/// Routing thresholds applied to a Choice answer. These are policy knobs, not
/// measured accuracy guarantees.
pub(all) struct Thresholds {
  min_probability : Double
  min_confidence : Double
} derive(Eq, Debug)

///|
/// The three fixed Choice labels. Fixed labels keep model output from becoming
/// free-form text.
pub let label_violation : String = "violation"

///|
pub let label_compliant : String = "compliant"

///|
pub let label_insufficient : String = "insufficient_evidence"

///|
pub(all) struct Question {
  instructions : String
  violation : String
  compliant : String
  insufficient_evidence : String
} derive(Eq, Debug)

///|
pub(all) struct Rule {
  id : String
  source : String?
  severity : Severity
  globs : Array[String]
  exclude : Array[String]
  context : Array[String]
  thresholds : Thresholds
  question : Question
  message : String
} derive(Eq, Debug)

///|
pub(all) struct Config {
  version : Int
  model : String
  rules : Array[Rule]
} derive(Eq, Debug)

///|
/// A validated Choice answer. Probabilities are retained exactly as returned;
/// confidence is never computed locally.
pub(all) struct ChoiceAnswer {
  choice : String
  p_violation : Double
  p_compliant : Double
  p_insufficient : Double
  confidence : Double
} derive(Eq, Debug)

///|
pub fn ChoiceAnswer::probability_of(self : ChoiceAnswer, label : String) -> Double {
  if label == label_violation {
    self.p_violation
  } else if label == label_compliant {
    self.p_compliant
  } else {
    self.p_insufficient
  }
}

///|
pub fn ChoiceAnswer::to_json_value(self : ChoiceAnswer) -> Json {
  let probs : Map[String, Json] = Map([])
  probs[label_violation] = Json::number(self.p_violation)
  probs[label_compliant] = Json::number(self.p_compliant)
  probs[label_insufficient] = Json::number(self.p_insufficient)
  Json::object({
    "type": Json::string("choice"),
    "choice": Json::string(self.choice),
    "probabilities": Json::object(probs),
    "confidence": Json::number(self.confidence),
  })
}

///|
pub(all) struct JevResponse {
  model : String
  answers : Map[String, ChoiceAnswer]
}

///|
/// Policy outcome for one evaluated rule.
pub(all) enum Decision {
  DecideCompliant
  DecideViolation
  DecideReview
} derive(Eq, Debug)

///|
pub(all) enum ResultStatus {
  StatusNotApplicable
  StatusCompliant
  StatusViolation
  StatusReview
  StatusError
} derive(Eq, Debug)

///|
pub fn ResultStatus::label(self : ResultStatus) -> String {
  match self {
    StatusNotApplicable => "not_applicable"
    StatusCompliant => "compliant"
    StatusViolation => "violation"
    StatusReview => "review"
    StatusError => "error"
  }
}

///|
pub(all) struct RuleResult {
  id : String
  status : ResultStatus
  severity : Severity
  source : String?
  message : String
  paths : Array[String]
  model : String?
  answer : ChoiceAnswer?
}

///|
pub(all) enum Conclusion {
  ConcIncomplete
  ConcBlocked
  ConcAdvisory
  ConcPass
  ConcNotApplicable
} derive(Eq, Debug)

///|
pub fn Conclusion::label(self : Conclusion) -> String {
  match self {
    ConcIncomplete => "incomplete"
    ConcBlocked => "blocked"
    ConcAdvisory => "advisory"
    ConcPass => "pass"
    ConcNotApplicable => "not_applicable"
  }
}

///|
pub(all) struct Report {
  base : String?
  head : String?
  merge_base : String?
  config_ref : String?
  requested_model : String
  results : Array[RuleResult]
  errors : Array[String]
}

///|
pub(all) enum OutputFormat {
  FormatText
  FormatJson
  FormatGithub
} derive(Eq, Debug)

///|
pub fn parse_format(text : String) -> OutputFormat raise {
  match text {
    "text" => FormatText
    "json" => FormatJson
    "github" => FormatGithub
    _ =>
      raise GateError(
        "Unknown --format '\{sanitize_line(text)}'. Expected text, json, or github.",
      )
  }
}
