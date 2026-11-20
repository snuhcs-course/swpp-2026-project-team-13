# Exam feedback and beta ratings

New exams use `ai-melodic-v3`. A numeric grade is always returned for a readable
provider response, including a blank or ambiguous answer. Provider failures are
retryable failures, not invented zero scores. Existing job snapshots remain valid.

## Short coaching

The grading request receives the current answer and reference only. After its
score is validated, a separate B-3 coaching request receives those materials and
a frozen factual summary of at most eight previous completed Exams by that user.
It receives no Practice/minigame data, experiment results, or previous advice.
Uncertain observations are excluded. History is optional evidence, not a skill
diagnosis. Retries preserve the same historical cutoff and prompt text.

`feedback.coach` adds `headline`, `detail`, `kind`, `history_used`,
`history_evidence_ids`, `evidence`, `evidence_warning` and `prompt_version`.
The existing `summary` and `recommendations` remain available for older clients.
The app shows the short coach text together with the score and rating on the
right; tapping the text reads it in full. Coaching has at most 45 seconds within
the original job deadline. Failure uses brief current-answer guidance and keeps
the valid score. There is no automatic paid retry. Raw response, usage, prompt
and historical context are retained in `GradingJob.coaching` for audit.

## Error marks

`reference_annotations` contains sparse verified reference-image marks:
`id`, `measure`, `style` (`glyph`, `underline`, `measure`), `message`, normalized
`bbox` and `glyphs` (normalized SVG path commands and boxes).
In v3 only, note indices refer to the reference MusicXML `note` order, including
rests and written tied notes. Earlier ambiguous index contracts, extra notes,
out-of-range indices and unavailable geometry use a measure rectangle.
Suggestions and uncertain recognition are not painted as definite errors.

The server-only `engraving/exam-note-map-v1.json` matches exact source/image hashes
and verifies note/rest counts and pitched note positions. Its accompanying
manifest pins the map hash. It covers all 387 current Exam reference images and
3,096 measures. It is never bundled or sent as a full bank to a device.
Build: `python scripts/build_exam_note_map.py` (uses the original local MuseScore
export cache); check: `python scripts/test_exam_feedback.py` (no cache needed).

## Optional beta survey (enabled by default)

Set `AI_FEEDBACK_RATINGS_ENABLED=true` in `backend/.env`. Omission also means true.
To stop collecting, set it to `false` and recreate the API and worker containers:

```sh
docker compose --env-file backend/.env up --build -d --wait
```

This hides the rating entry point after refreshing the result and rejects new
writes. Existing rows and grades remain unchanged. Enabling it again restores
the entry point and the user's existing evaluation.

Completed Exam results include:

```json
{"feedback_rating":{"enabled":true,"feedback_id":"<sha256>","rating":null}}
```

The optional sheet asks for 1–5 stars and a reason of at most 500 Unicode code
points. Stars are required; the reason may be empty. It does not open
automatically. A failed save retains the form contents for retry.

`PUT /api/v1/attempts/{attempt_id}/feedback-rating/`, authenticated as the owner:

```json
{"job_id":"<completed-job-uuid>","feedback_id":"<sha256-from-result>","stars":4,"reason":"The measure comparison helped."}
```

Returns the updated `feedback_rating` state (without the wrapper), including
`rating.stars`, `rating.reason`, and `rating.updated_at`. Repeating the PUT or
editing it updates the one evaluation for this exact grading job. A mismatched
feedback identity is rejected. Pending/failed jobs, Practice, and other users'
results cannot be rated. No exam points, rating changes, recommendation state,
or model prompts are modified by a survey response.

The row freezes the feedback content, source grading/coaching prompt versions,
model, coaching request ID and feedback digest for later analysis. The optional
text is beta research data; it is never added to AI prompts or public assets.
Deleting the account removes the evaluations with its grading jobs.

Review in Django admin → AI feedback ratings, or export JSONL locally:

```sh
docker compose --env-file backend/.env exec -T api python manage.py export_feedback_ratings > backend/.local/feedback-ratings.jsonl
```

Keep that export private and outside Git. The demo API stores its survey locally
in its separate demo account scope; those rows do not enter server telemetry.
