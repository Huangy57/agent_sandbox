#! /bin/bash --
# chaperon/handlers/srun.sh — Handle srun requests from sandbox
#
# Proxies srun through the chaperon so it can authenticate with munge
# (which is blocked inside the sandbox).  Only allowed when SLURM_JOB_ID
# is set (inside an existing allocation — step launching only).
#
# The handler validates flags against a whitelist identical to the stub's,
# then execs real srun.  stdout/stderr are captured by the chaperon main
# loop and returned via the response FIFO.
#
# Security: munge is intentionally blocked inside the sandbox to prevent
# arbitrary job submission.  By proxying srun through the chaperon, we
# get munge access (chaperon runs outside) while still validating all args.

source "$(dirname "${BASH_SOURCE[0]}")/_handler_lib.sh"

# ── Allowed srun flags (step mode only) ─────────────────────────
_SRUN_ALLOWED_FLAGS=" \
  -n --ntasks \
  -N --nodes \
  -c --cpus-per-task \
  -G --gpus \
  --gpus-per-node \
  --gpus-per-task \
  --cpus-per-gpu \
  --mem \
  --mem-per-cpu \
  --mem-per-gpu \
  --gres \
  -w --nodelist \
  -x --exclude \
  --exclusive \
  -l --label \
  -o --output \
  -e --error \
  -i --input \
  --mpi \
  --distribution \
  --ntasks-per-node \
  --ntasks-per-gpu \
  --threads-per-core \
  --cpu-bind \
  --mem-bind \
  --gpu-bind \
  --spread-job \
  --exact \
  --overlap \
  --het-group \
  --multi-prog \
  --kill-on-bad-exit \
  --unbuffered \
  -v --verbose \
  -Q --quiet \
  --help \
  --usage \
  --version \
"

_SRUN_VALUE_FLAGS=" \
  -n --ntasks \
  -N --nodes \
  -c --cpus-per-task \
  -G --gpus \
  --gpus-per-node \
  --gpus-per-task \
  --cpus-per-gpu \
  --mem \
  --mem-per-cpu \
  --mem-per-gpu \
  --gres \
  -w --nodelist \
  -x --exclude \
  -o --output \
  -e --error \
  -i --input \
  --mpi \
  --distribution \
  --ntasks-per-node \
  --ntasks-per-gpu \
  --threads-per-core \
  --cpu-bind \
  --mem-bind \
  --gpu-bind \
  --het-group \
  --multi-prog \
  --kill-on-bad-exit \
"

_is_srun_allowed() {
    local base="${1%%=*}"
    [[ "$_SRUN_ALLOWED_FLAGS" == *" $base "* ]]
}

_is_srun_value_flag() {
    [[ "$_SRUN_VALUE_FLAGS" == *" $1 "* ]]
}

handle_srun() {
    local project_dir="$1"
    local sandbox_exec="$2"

    local real_srun="${REAL_SRUN:-/usr/bin/srun}"
    if [[ ! -x "$real_srun" ]]; then
        echo "chaperon: real srun not found at $real_srun" >&2
        return 1
    fi

    # srun is only allowed inside an existing allocation
    if [[ -z "${SLURM_JOB_ID:-}" ]]; then
        echo "chaperon: srun denied — not inside a Slurm allocation (SLURM_JOB_ID not set)" >&2
        echo "Hint: use 'sbatch --wrap=\"command\"' for job submission." >&2
        return 1
    fi

    # Validate CWD
    if [[ -n "$REQ_CWD" ]]; then
        if ! validate_cwd "$REQ_CWD" "$project_dir"; then
            return 1
        fi
    fi

    # Validate and filter arguments
    local validated_args=()
    local i=0
    local found_separator=false
    while (( i < ${#REQ_ARGS[@]} )); do
        local arg="${REQ_ARGS[$i]}"

        # After "--", everything is the command — pass through
        if [[ "$arg" == "--" ]]; then
            found_separator=true
            validated_args+=("$arg")
            (( i++ )) || true
            while (( i < ${#REQ_ARGS[@]} )); do
                validated_args+=("${REQ_ARGS[$i]}")
                (( i++ )) || true
            done
            break
        fi

        case "$arg" in
            # Explicitly denied flags
            --jobid|--jobid=*|-j)
                echo "chaperon: srun flag '$arg' denied (cannot attach to arbitrary allocations)" >&2
                return 1
                ;;
            --uid|--uid=*|--gid|--gid=*)
                echo "chaperon: srun flag '$arg' denied (cannot impersonate)" >&2
                return 1
                ;;
            --export|--export=*)
                echo "chaperon: srun flag '$arg' denied (env injection blocked)" >&2
                return 1
                ;;
            --chdir|--chdir=*|-D)
                echo "chaperon: srun flag '$arg' denied (CWD controlled by sandbox)" >&2
                return 1
                ;;
            --get-user-env|--get-user-env=*)
                echo "chaperon: srun flag '$arg' denied (env leakage blocked)" >&2
                return 1
                ;;
            --propagate|--propagate=*)
                echo "chaperon: srun flag '$arg' denied (rlimit propagation blocked)" >&2
                return 1
                ;;
            --prolog|--prolog=*|--epilog|--epilog=*|--task-prolog|--task-prolog=*|--task-epilog|--task-epilog=*)
                echo "chaperon: srun flag '$arg' denied (arbitrary script execution)" >&2
                return 1
                ;;
            --bcast|--bcast=*)
                echo "chaperon: srun flag '$arg' denied (binary broadcast blocked)" >&2
                return 1
                ;;
            --container|--container=*)
                echo "chaperon: srun flag '$arg' denied (OCI containers bypass sandbox)" >&2
                return 1
                ;;
            --network|--network=*)
                echo "chaperon: srun flag '$arg' denied (network namespace manipulation)" >&2
                return 1
                ;;
            -A|--account|--account=*|-p|--partition|--partition=*|-q|--qos|--qos=*|-t|--time|--time=*|--reservation|--reservation=*)
                echo "chaperon: srun flag '$arg' denied (allocation flags not allowed in step mode)" >&2
                return 1
                ;;
            --*=*)
                if _is_srun_allowed "$arg"; then
                    validated_args+=("$arg")
                else
                    echo "chaperon: srun denied unknown flag: ${arg%%=*}" >&2
                    return 1
                fi
                ;;
            -*)
                if _is_srun_allowed "$arg"; then
                    validated_args+=("$arg")
                    if _is_srun_value_flag "$arg" && (( i + 1 < ${#REQ_ARGS[@]} )); then
                        (( i++ )) || true
                        validated_args+=("${REQ_ARGS[$i]}")
                    fi
                else
                    echo "chaperon: srun denied unknown flag: $arg" >&2
                    return 1
                fi
                ;;
            *)
                # Positional: start of command — pass through rest
                validated_args+=("$arg")
                (( i++ )) || true
                while (( i < ${#REQ_ARGS[@]} )); do
                    validated_args+=("${REQ_ARGS[$i]}")
                    (( i++ )) || true
                done
                break
                ;;
        esac
        (( i++ )) || true
    done

    # Execute real srun with validated args.
    # The chaperon runs outside the sandbox and has munge access.
    # CWD is set to the validated directory.
    local rc=0
    if [[ -n "$REQ_CWD" ]]; then
        (cd "$REQ_CWD" && "$real_srun" "${validated_args[@]}") || rc=$?
    else
        "$real_srun" "${validated_args[@]}" || rc=$?
    fi
    return "$rc"
}
