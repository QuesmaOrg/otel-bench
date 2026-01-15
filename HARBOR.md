Harbor playground
=====

This is just a toy repo to document how to work with [Harbor framework](https://harborframework.com).

:warning: Prerequisites:
* Make sure to install Harbor (`uv tool install harbor`).
* Set `ANTHROPIC_API_KEY` (or any LLM API key - depending on model/agent chosen). LiteLLM is being used under the hood.

#### Example task run

In this repository you can find harbor-compatible tasks in two places
* `tasks/` directory which contains sample tasks
* `datasets/compilebench` which is complete dataset from our [CompileBench](https://github.com/QuesmaOrg/CompileBench) ported to Harbor

**WARNING**: When running tasks from different location you have to use specific flags (`-p`/`-t`, etc.)


A default agent used in Terminal-bench is available (it can also use different models) once you set `ANTHROPIC_API_KEY`.
```shell
harbor run -p "tasks/curl-ssl-arm64-static"  --agent terminus-2 --model claude-sonnet-4-5-20250929
```

If you have Claude code you can also use it - Harbor runs it locally in non-interactive mode:
```shell
harbor run -p "tasks/compile-simple-go"  --agent claude-code
```

By default, the tasks run locally in Docker. You can add `--no-delete` if you'd like to keep container running after
the task is finished (e.g. to verify some checks).


#### UI

You run web UI (available since Harbor 0.1.25, released on Dec 17th 2025):
```
harbor view jobs/
```
`jobs/` is just path to the default trajectory files directory.
The command spins up UI at http://localhost:8080

Just for the reference, our old self-made UI:
<details>

I've vibe-coded a minimalistic UI to view task runs and results.
```shell
cd ui/
python3 server.py
```
That's basically ~200 LoC simple Python http server watching `jobs/` directory, where `harbor` logs the agent run
action/results/metadata in [Agent Trajectory Format](https://harborframework.com/docs/trajectory-format).

For nice looks I've used VueJS and Tailwind CSS.
</details>

#### Useful commands

Running multiple tasks from local `tasks` directory:
```bash
harbor run -p tasks/ -t curl-ssl -t curl-ssl-arm64-static \
    --agent terminus-2 \
    --model claude-sonnet-4-5-20250929
```
There's an option to set concurrency with `--n-concurrent`/`-n` flag (default: 4).

Running tasks from local Compilebench dataset using matcher with multiple attempts of the same task:
```bash
harbor run  --agent terminus-2 --model claude-sonnet-4-5-20250929 -p datasets/compilebench \
    -n 6 -k 3 \
    -t "coreutils-old-version-*"
```

Run all compilebench tasks, 3 attempts each):
```bash
harbor run  --agent terminus-2 --model claude-sonnet-4-5-20250929 \
    -p datasets/compilebench -n 6 -k 3
```

Run task without agent to try solving it yourself:
```bash
harbor tasks start-env -p datasets/compilebench/coreutils-old-version -i

# Once inside, you can run:
cd /workdir
bash /solution/solve.sh
# or test it
cd /tests && pytest
```

Using OpenRouter

```bash
# Export your key
export OPENROUTER_API_KEY=...
# Ensure there's openrouter prefix within --model flag
harbor run -p "tasks/compile-simple-go" --agent terminus-2 --model openrouter/anthropic/claude-3.5-sonnet
```

Force rebuild docker image:
```bash
harbor run -p "tasks/example-task-airgapped" --agent terminus-2 --model openrouter/anthropic/claude-sonnet-4.5 --force-build
```