# Simple COC 5 timing override

Apply the complete Simple COC protocol without omission, with exactly one
substitution:

- In every one of the 20 measured transition blocks, use
  `{ "wait": 5000 }` before `qualification_dispatch` instead of
  `{ "wait": 10000 }`.

The initial Windhelm positioning stabilization remains 10,000 ms. The strict
qualification timeout remains 30,000 ms. Do not shorten any capture timeout,
receipt timeout, fidelity check, or failure deadline, and do not add another
fixed pacing wait between measured transitions. Qualification and telemetry
work can make the observed wall-clock COC-to-COC interval longer than five
seconds; 5,000 ms is the deliberate post-qualification pacing delay.
