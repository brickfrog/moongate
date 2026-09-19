///|
/// Maps a validated Choice answer onto a rule decision.
///
/// Only a decisive answer that clears both thresholds is taken at face value.
/// Everything else routes to review, including every `insufficient_evidence`
/// answer: absence of evidence is never treated as compliance.
///
/// The thresholds are routing values chosen before any measurement on this
/// repository; clearing them is not evidence that a verdict is correct.
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
///
/// A rule that could not be evaluated is judged by its own severity, exactly
/// like a rule that was. A blocking rule must never pass unproven, so it
/// concludes `incomplete`; an advisory rule never had the authority to stop a
/// merge, so "could not look" cannot be graver than "looked and found a
/// violation", which is advisory. Run-level failures — bad configuration, no
/// merge base, a dead transport — are in `errors` and remain unconditional.
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
      StatusError =>
        if result.severity == Blocking {
          return ConcIncomplete
        } else {
          all_compliant = false
          advisory = true
        }
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
