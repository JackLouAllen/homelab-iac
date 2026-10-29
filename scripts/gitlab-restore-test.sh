#!/usr/bin/env bash
# Prove a GitLab backup restores: start a brand-new GitLab (same version) in a throwaway container with
# nothing in it, restore the archive, and check that the data is there and the secrets decrypt.
#
#   gitlab-restore-test.sh ARCHIVE SECRETS_JSON GITLAB_RB
#
#   ARCHIVE       <timestamp>_<date>_<version>_gitlab_backup.tar (from /srv/gitlab/backups, or out of restic)
#   SECRETS_JSON  /etc/gitlab/gitlab-secrets.json from the same server (the archive does not hold it; without
#                 it encrypted data such as CI variables and 2FA secrets cannot be read)
#   GITLAB_RB     /etc/gitlab/gitlab.rb from the same server
#
# The image version is taken from the archive's name, so it always matches. Runs with docker or podman.
# Needs about 3 GB of memory for a few minutes. Nothing here touches a real server.
set -euo pipefail

archive=${1:?usage: gitlab-restore-test.sh ARCHIVE SECRETS_JSON GITLAB_RB}
secrets=${2:?usage: gitlab-restore-test.sh ARCHIVE SECRETS_JSON GITLAB_RB}
rb=${3:?usage: gitlab-restore-test.sh ARCHIVE SECRETS_JSON GITLAB_RB}
for f in "$archive" "$secrets" "$rb"; do [ -r "$f" ] || { echo "cannot read $f" >&2; exit 1; }; done

engine=$(command -v docker || command -v podman) || { echo "needs docker or podman" >&2; exit 1; }
name=gitlab-restore-test
base=$(basename "$archive")
# 1793232972_2026_10_29_19.5.1_gitlab_backup.tar -> backup id and version
backup_id=${base%_gitlab_backup.tar}
version=${backup_id##*_}
image=gitlab/gitlab-ce:${version}-ce.0
work=$(mktemp -d)
cleanup() { "$engine" rm -f "$name" > /dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT

# The container may rewrite these two files, so it gets copies
cp "$secrets" "$work/gitlab-secrets.json"
cp "$rb" "$work/gitlab.rb"
# GitLab refuses a root password made of common words: use a random one (it is replaced by the restore)
pw=$(openssl rand -base64 24 | tr -d '/+=' | head -c 28)

echo "image: $image"
"$engine" rm -f "$name" > /dev/null 2>&1 || true
"$engine" run -d --name "$name" --shm-size 256m -e GITLAB_ROOT_PASSWORD="$pw" \
    -v "$work/gitlab.rb:/etc/gitlab/gitlab.rb" -v "$work/gitlab-secrets.json:/etc/gitlab/gitlab-secrets.json" \
    "$image" > /dev/null

run() { "$engine" exec "$name" "$@"; }
ready() { run curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8181/-/readiness 2> /dev/null || true; }
wait_ready() { for _ in $(seq 1 120); do [ "$(ready)" = 200 ] && return 0; sleep 5; done; return 1; }

echo "waiting for the empty GitLab to configure itself (a few minutes)..."
# Read the log into a variable first: with pipefail, "docker logs | grep -q" is reported as failed when
# grep exits early and docker logs is killed by SIGPIPE, so a long log made this loop wait forever.
for _ in $(seq 1 120); do
    logs=$("$engine" logs "$name" 2>&1 || true)
    grep -q "gitlab Reconfigured!" <<< "$logs" && break
    grep -qiE "Chef Infra Client failed|FATAL:" <<< "$logs" && { echo "the empty GitLab failed to configure" >&2; exit 1; }
    sleep 3
done
wait_ready || { echo "the empty GitLab never became ready" >&2; exit 1; }
# Every gitlab-rails command starts the whole Rails application: about a minute each, silently.
echo "checking the empty instance (each check takes about a minute)..."
echo "empty instance: projects = $(run gitlab-rails runner 'puts Project.count' 2> /dev/null | tail -1)"

backup_dir=$(run gitlab-rails runner 'puts Gitlab.config.backup.path' 2> /dev/null | tail -1)
"$engine" cp "$archive" "$name:$backup_dir/$base"
run sh -c "chown git:git '$backup_dir/$base' && chmod 600 '$backup_dir/$base'"
run gitlab-ctl stop puma > /dev/null
run gitlab-ctl stop sidekiq > /dev/null

echo "restoring $backup_id (about a minute)..."
run gitlab-backup restore BACKUP="$backup_id" GITLAB_ASSUME_YES=1 > "$work/restore.log" 2>&1 || { tail -20 "$work/restore.log"; echo "RESTORE FAILED" >&2; exit 1; }
grep -E "Restoring (database|repositories|uploads) \.\.\. done" "$work/restore.log" | sed 's/^/  /'
echo "restarting GitLab and waiting for it (a minute or two)..."
run gitlab-ctl restart > /dev/null
wait_ready || { echo "GitLab did not come back after the restore" >&2; exit 1; }

echo "counting what came back (about a minute)..."
echo "restored instance:"
run gitlab-rails runner '
  puts "  users     = #{User.count}"
  puts "  projects  = #{Project.count}"
  bad = Project.all.reject { |p| p.repository.exists? && !p.repository.empty? }
  puts "  projects whose repository is missing or empty: #{bad.map(&:full_path).inspect}"
  puts "  commits on default branches: #{Project.all.sum { |p| p.repository.exists? && !p.repository.empty? ? p.repository.commit_count : 0 }}"
' 2> /dev/null | tail -4

echo "secrets check (every encrypted value must decrypt with the secrets file; about a minute):"
doctor=$(run gitlab-rake gitlab:doctor:secrets 2>&1)
tables=$(printf '%s\n' "$doctor" | grep -c "failures: " || true)
failed=$(printf '%s\n' "$doctor" | grep "failures: " | grep -vc "failures: 0" || true)
echo "  $tables kinds of encrypted data checked, $failed with failures"
if [ "$failed" != 0 ]; then
    printf '%s\n' "$doctor" | grep "failures: " | grep -v "failures: 0" | sed 's/^.*INFO -- : /  /'
    echo "RESTORE TEST FAILED: some encrypted data could not be decrypted (wrong secrets file?)" >&2
    exit 1
fi
echo "RESTORE TEST PASSED"
