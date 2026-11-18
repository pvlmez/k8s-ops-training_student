# Example 09 — Job: run to completion

**Shows:** a Job runs pods until a number of them have **succeeded**, a few
in parallel, and gives up after too many failures. Pods that finished stay
around, so you can read their logs.

**Objects:** Job · **Namespace:** `ex-job` · **About 5 minutes**

`$` = workstation · [All examples](../README.md)

![The Job controller starts pods, at most parallelism at a time, until completions pods have succeeded or backoffLimit pods have failed](diagram.svg)

## Apply

```bash
$ cd "$K8S_COURSE_HOME"
$ cat examples/09-job/job.yaml
$ kubectl apply -f examples/09-job/job.yaml
$ kubectl -n ex-job get pods
$ kubectl -n ex-job wait --for=condition=Complete job/batch --timeout=180s
```

Run `kubectl -n ex-job get pods -w` in a second terminal while it runs: two
pods at a time, each `Running` for 8 seconds, then `Completed`.

## Look at it

```bash
$ kubectl -n ex-job get job batch
$ kubectl -n ex-job get pods
$ kubectl -n ex-job logs job/batch
$ kubectl -n ex-job logs -l job-name=batch --prefix
```

- `COMPLETIONS 4/4` and four pods in `Completed`. They are kept (and use no
  CPU or memory) until the Job is deleted, or until
  `ttlSecondsAfterFinished` deletes it.
- `logs job/batch` picks one pod; `-l job-name=batch` reads all of them.
  The timestamps show two pods at a time.

## Try this

**A Job that fails.** Each pod exits with code 1:

```bash
$ kubectl apply -f examples/09-job/job-fail.yaml
$ kubectl -n ex-job wait --for=condition=Failed job/failing --timeout=180s
$ kubectl -n ex-job get job failing
$ kubectl -n ex-job get pods -l job-name=failing
$ kubectl -n ex-job describe job failing | tail -5
$ kubectl -n ex-job logs -l job-name=failing --tail=1
```

Three pods failed (1 try + `backoffLimit: 2`), each after a longer wait
than the last. The Job's condition is `Failed` with reason
`BackoffLimitExceeded`, and the logs say why.

## What to remember

- A Job is done when `completions` pods have exited with code 0. A pod that
  fails is replaced, up to `backoffLimit` times.
- Its pods use `restartPolicy: Never` or `OnFailure`: a Job's work is meant
  to finish.
- After a failed backup or migration, look at the Job's events and at the
  logs of its pods (`-l job-name=<job>`); they are kept for that.

## Clean up

```bash
$ kubectl delete namespace ex-job
```
