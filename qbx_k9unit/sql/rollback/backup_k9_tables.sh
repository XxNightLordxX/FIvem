#!/usr/bin/env bash
#
# qbx_k9unit :: back up this resource's five database tables
# =====================================================================
#
# RUN THIS BEFORE ANY ROLLBACK OR UNINSTALL. It is the only way back.
#
# It saves a copy of the five tables qbx_k9unit owns:
#     k9_certifications   who is certified, granted/revoked by whom
#     k9_search_log       every contraband search ever performed
#     k9_partnerships     every K9/handler partnership, past and present
#     k9_progression      every player's accumulated K9 XP
#     k9_permissions      every named permission grant/revoke, and by whom
#
# ...into a single timestamped .sql file, and prints the one command that
# puts it all back. It touches nothing else in your database, and it makes
# no changes at all -- it only reads.
#
# USAGE (simplest form -- it will ask for your password):
#     ./backup_k9_tables.sh -d your_database_name -u your_mysql_user
#
# OTHER OPTIONS:
#     -d NAME    database name                (required)
#     -u USER    MySQL username               (default: root)
#     -h HOST    server hostname              (default: 127.0.0.1)
#     -P PORT    server port                  (default: 3306)
#     -S PATH    unix socket, instead of -h/-P
#     -o DIR     where to write the backup    (default: current directory)
#     -w PASS    password on the command line (NOT recommended -- other
#                users on the machine can see it; just omit it and let
#                the script prompt you instead)
#
# EXIT CODE: 0 means the backup succeeded and the file is safe to rely on.
# Anything else means it did NOT -- do not proceed with a rollback.
# =====================================================================

set -euo pipefail

DB=""; USER="root"; HOST="127.0.0.1"; PORT="3306"; SOCKET=""; OUTDIR="."; PASS=""

while getopts ":d:u:h:P:S:o:w:" opt; do
    case "$opt" in
        d) DB="$OPTARG" ;;
        u) USER="$OPTARG" ;;
        h) HOST="$OPTARG" ;;
        P) PORT="$OPTARG" ;;
        S) SOCKET="$OPTARG" ;;
        o) OUTDIR="$OPTARG" ;;
        w) PASS="$OPTARG" ;;
        \?) echo "ERROR: unknown option -$OPTARG. Run with no arguments to see usage." >&2; exit 2 ;;
        :)  echo "ERROR: option -$OPTARG needs a value." >&2; exit 2 ;;
    esac
done

if [ -z "$DB" ]; then
    echo "ERROR: you must say which database to back up, with -d" >&2
    echo "" >&2
    echo "   Example:  ./backup_k9_tables.sh -d your_database_name -u your_mysql_user" >&2
    echo "" >&2
    echo "   (Your database name is the same one you ran sql/install.sql against." >&2
    echo "    In txAdmin it is usually shown on the server's Settings page.)" >&2
    exit 2
fi

# --- locate the client binaries (MariaDB renamed them; support both) ----
if command -v mysqldump >/dev/null 2>&1; then DUMP_BIN="mysqldump"
elif command -v mariadb-dump >/dev/null 2>&1; then DUMP_BIN="mariadb-dump"
else
    echo "ERROR: neither 'mysqldump' nor 'mariadb-dump' is installed on this machine." >&2
    echo "       Install your database's client tools, or run this script on the" >&2
    echo "       database server itself." >&2
    exit 3
fi
if command -v mysql >/dev/null 2>&1; then CLI_BIN="mysql"
elif command -v mariadb >/dev/null 2>&1; then CLI_BIN="mariadb"
else
    echo "ERROR: neither 'mysql' nor 'mariadb' is installed on this machine." >&2
    exit 3
fi

# --- password: prompt rather than take it on the command line -----------
if [ -z "$PASS" ]; then
    printf "MySQL password for user '%s' (leave blank if there is none): " "$USER" >&2
    read -r -s PASS
    echo "" >&2
fi
export MYSQL_PWD="$PASS"   # keeps the password out of the process list

if [ -n "$SOCKET" ]; then CONN=(--socket="$SOCKET" --user="$USER")
else                      CONN=(--host="$HOST" --port="$PORT" --user="$USER"); fi

# --- check we can actually connect before promising anything ------------
if ! "$CLI_BIN" "${CONN[@]}" --batch --skip-column-names -e "SELECT 1" "$DB" >/dev/null 2>&1; then
    echo "ERROR: could not connect to database '$DB' as user '$USER'." >&2
    echo "       Check the database name, username and password, and that the" >&2
    echo "       server is running. Nothing has been changed." >&2
    exit 4
fi

# --- work out which of the five tables actually exist -------------------
# Dumping a table that does not exist makes mysqldump fail outright, so a
# database that only ever ran part of the install still backs up cleanly.
ALL_TABLES=(k9_certifications k9_search_log k9_partnerships k9_progression k9_permissions)
PRESENT=()
MISSING=()
for t in "${ALL_TABLES[@]}"; do
    n=$("$CLI_BIN" "${CONN[@]}" --batch --skip-column-names -e \
        "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA='$DB' AND TABLE_NAME='$t';" 2>/dev/null || echo 0)
    if [ "$n" = "1" ]; then PRESENT+=("$t"); else MISSING+=("$t"); fi
done

if [ "${#PRESENT[@]}" -eq 0 ]; then
    echo "ERROR: none of the five qbx_k9unit tables exist in database '$DB'." >&2
    echo "       There is nothing to back up. Check you named the right database." >&2
    exit 5
fi

mkdir -p "$OUTDIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUTFILE="$OUTDIR/qbx_k9unit-backup-${DB}-${STAMP}.sql"

echo "Backing up ${#PRESENT[@]} table(s) from '$DB': ${PRESENT[*]}"
if [ "${#MISSING[@]}" -gt 0 ]; then
    echo "  (not present in this database, so not backed up: ${MISSING[*]})"
fi

# --single-transaction : a consistent snapshot without locking the tables,
#                        so a live server keeps running normally throughout.
# --no-tablespaces     : required on MySQL 8 unless the user holds the
#                        PROCESS privilege. Not understood by older
#                        mysqldump builds, hence the retry below.
DUMP_ARGS=(--single-transaction --routines=FALSE --events=FALSE
           --add-drop-table --complete-insert --default-character-set=utf8mb4)

set +e
"$DUMP_BIN" "${CONN[@]}" "${DUMP_ARGS[@]}" --no-tablespaces "$DB" "${PRESENT[@]}" > "$OUTFILE" 2>"$OUTFILE.err"
rc=$?
if [ $rc -ne 0 ] && grep -qi "unknown option\|no-tablespaces" "$OUTFILE.err" 2>/dev/null; then
    "$DUMP_BIN" "${CONN[@]}" "${DUMP_ARGS[@]}" "$DB" "${PRESENT[@]}" > "$OUTFILE" 2>"$OUTFILE.err"
    rc=$?
fi
set -e

if [ $rc -ne 0 ]; then
    echo "ERROR: the backup FAILED. Do not run any rollback or uninstall script." >&2
    echo "       The database itself is unchanged. Error from $DUMP_BIN:" >&2
    sed 's/^/       /' "$OUTFILE.err" >&2
    rm -f "$OUTFILE"
    exit 6
fi

# --- verify the file is real before telling anyone it worked ------------
if [ ! -s "$OUTFILE" ]; then
    echo "ERROR: the backup file came out empty. Treat this as a FAILED backup." >&2
    rm -f "$OUTFILE" "$OUTFILE.err"
    exit 7
fi
for t in "${PRESENT[@]}"; do
    if ! grep -q "CREATE TABLE \`$t\`" "$OUTFILE"; then
        echo "ERROR: table '$t' is missing from the backup file. Treat this as a FAILED backup." >&2
        exit 8
    fi
done
rm -f "$OUTFILE.err"

SIZE="$(du -h "$OUTFILE" | cut -f1)"

echo ""
echo "======================================================================"
echo " BACKUP OK"
echo "======================================================================"
echo " File: $OUTFILE"
echo " Size: $SIZE"
echo ""
echo " Rows saved:"
for t in "${PRESENT[@]}"; do
    c=$("$CLI_BIN" "${CONN[@]}" --batch --skip-column-names -e "SELECT COUNT(*) FROM \`$t\`;" "$DB" 2>/dev/null || echo "?")
    printf "   %-20s %s\n" "$t" "$c"
done
echo ""
echo " TO PUT IT ALL BACK, run exactly this one line:"
echo ""
if [ -n "$SOCKET" ]; then
    echo "   $CLI_BIN --socket=$SOCKET -u $USER -p $DB < $OUTFILE"
else
    echo "   $CLI_BIN -h $HOST -P $PORT -u $USER -p $DB < $OUTFILE"
fi
echo ""
echo " (It will ask for the same password you just typed. Restoring REPLACES"
echo "  the five tables with the versions saved in this file.)"
echo ""
echo " Keep this file somewhere safe -- copy it off the server if you can."
echo "======================================================================"
