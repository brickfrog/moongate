///|
/// Maps a validated Choice answer onto a rule decision.
///
/// Only a decisive answer that clears both thresholds is taken at face value.
/// Everything else routes to review, including every `insufficient_evidence`
/// answer: absence of evidence is never treated as compliance.
pub fn decide(rule : Rule, answer : ChoiceAnswer) -> Decision {
  let t = rule.thresholds
  let clears = answer.probability_of(answer.choice) >= t.min_probability &&
    answer.confidence >= t.min_confidence
  if !clears {
    return DecideReview
  }
  if answer.choice == label_violation {
    DecideViolation
  } else if answer.choice == label_compliant {
    DecideCompliant
  } else {
    DecideReview
  }
}

///|
/// Overall conclusion, in precedence order: incomplete, blocked, advisory,
/// pass, not applicable.
pub fn Report::conclusion(self : Report) -> Conclusion {
  if !self.errors.is_empty() {
    return ConcIncomplete
  }
  let mut evaluated = 0
  let mut all_compliant = true
  let mut blocked = false
  let mut advisory = false
  for result in self.results {
    match result.status {
      StatusError => return ConcIncomplete
      StatusViolation => {
        evaluated += 1
        all_compliant = false
        if result.severity == Blocking {
          blocked = true
        } else {
          advisory = true
        }
      }
      StatusReview => {
        evaluated += 1
        all_compliant = false
        advisory = true
      }
      StatusCompliant => evaluated += 1
      StatusNotApplicable => ()
    }
  }
  if blocked {
    ConcBlocked
  } else if advisory {
    ConcAdvisory
  } else if evaluated > 0 && all_compliant {
    ConcPass
  } else {
    ConcNotApplicable
  }
}

///|
/// 0 advisory/pass, 1 blocking violation, 2 operational or configuration
/// failure. Errors always win.
pub fn Report::exit_code(self : Report) -> Int {
  match self.conclusion() {
    ConcIncomplete => 2
    ConcBlocked => 1
    _ => 0
  }
}
