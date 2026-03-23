#!/usr/bin/env python3
"""
============================================================
 PostgreSQL Slow Query Log Parser
 Parses PostgreSQL log files and summarises slow query patterns.
 Works with log_min_duration_statement output format.

 Usage:
   python3 parse_slow_logs.py /path/to/postgresql.log
   python3 parse_slow_logs.py /path/to/postgresql.log --threshold 2000 --top 20
   docker exec postgres_primary cat /var/lib/postgresql/data/log/*.log | python3 parse_slow_logs.py -
============================================================
"""
import re
import sys
import argparse
from collections import defaultdict
from datetime import datetime


# ─── Patterns ────────────────────────────────────────────────
DURATION_PATTERN = re.compile(
    r'(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}.\d+).*?'
    r'duration: ([\d.]+) ms\s+(?:statement|execute[^:]*): (.+)',
    re.DOTALL
)

# Normalise query: replace literals with placeholders
LITERAL_PATTERN = re.compile(
    r"'[^']*'"           # string literals
    r"|\b\d+\b"          # integers
    r"|'[^'\\]*(?:\\.[^'\\]*)*'"  # escaped strings
)


def normalise(query: str) -> str:
    """Replace literal values with ? for grouping similar queries."""
    q = query.strip().rstrip(';')
    q = LITERAL_PATTERN.sub('?', q)
    q = re.sub(r'\s+', ' ', q)
    return q[:300]


def parse_log(fileobj, threshold_ms: float = 1000.0):
    """Parse PostgreSQL log and collect slow query stats."""
    stats = defaultdict(lambda: {
        'count': 0,
        'total_ms': 0.0,
        'max_ms': 0.0,
        'min_ms': float('inf'),
        'samples': []
    })

    current_entry = []
    current_ts = None
    current_dur = None

    for line in fileobj:
        m = DURATION_PATTERN.match(line)
        if m:
            # Process previous entry if any
            if current_dur is not None and current_dur >= threshold_ms and current_entry:
                query_text = ' '.join(current_entry)
                norm = normalise(query_text)
                s = stats[norm]
                s['count'] += 1
                s['total_ms'] += current_dur
                s['max_ms'] = max(s['max_ms'], current_dur)
                s['min_ms'] = min(s['min_ms'], current_dur)
                if len(s['samples']) < 3:
                    s['samples'].append((current_ts, current_dur, query_text[:200]))

            current_ts = m.group(1)
            current_dur = float(m.group(2))
            current_entry = [m.group(3).strip()]
        elif current_dur is not None and line.startswith('\t'):
            # Continuation line
            current_entry.append(line.strip())

    return stats


def print_report(stats: dict, top_n: int = 15, threshold_ms: float = 1000.0):
    """Print a formatted slow query report."""
    if not stats:
        print(f"\nNo queries found exceeding {threshold_ms}ms threshold.\n")
        return

    print("\n" + "=" * 80)
    print(f"  POSTGRESQL SLOW QUERY REPORT  (threshold: {threshold_ms:.0f}ms)")
    print("=" * 80)
    print(f"  Unique query patterns: {len(stats)}")
    print(f"  Showing top {top_n} by total execution time\n")

    sorted_queries = sorted(stats.items(), key=lambda x: x[1]['total_ms'], reverse=True)

    for rank, (query, s) in enumerate(sorted_queries[:top_n], 1):
        avg_ms = s['total_ms'] / s['count']
        print(f"{'─' * 80}")
        print(f"  #{rank}  calls={s['count']}  "
              f"total={s['total_ms']/1000:.2f}s  "
              f"avg={avg_ms:.0f}ms  "
              f"max={s['max_ms']:.0f}ms  "
              f"min={s['min_ms']:.0f}ms")
        print(f"  Query: {query}")
        if s['samples']:
            print(f"  Last seen: {s['samples'][-1][0]}  ({s['samples'][-1][1]:.0f}ms)")
        print()

    print("=" * 80)

    # Summary table
    print("\nSUMMARY (sorted by total time):")
    print(f"{'Rank':<5} {'Calls':>7} {'Total(s)':>10} {'Avg(ms)':>9} {'Max(ms)':>9}  Query (truncated)")
    print("-" * 80)
    for rank, (query, s) in enumerate(sorted_queries[:top_n], 1):
        avg_ms = s['total_ms'] / s['count']
        short_q = query[:55].replace('\n', ' ')
        print(f"{rank:<5} {s['count']:>7} {s['total_ms']/1000:>10.2f} {avg_ms:>9.0f} {s['max_ms']:>9.0f}  {short_q}")

    print()


def main():
    parser = argparse.ArgumentParser(description="PostgreSQL Slow Query Log Analyser")
    parser.add_argument('logfile', nargs='?', default='-',
                        help="Path to PostgreSQL log file, or '-' for stdin")
    parser.add_argument('--threshold', type=float, default=1000.0,
                        help="Minimum query duration in ms to include (default: 1000)")
    parser.add_argument('--top', type=int, default=15,
                        help="Number of top queries to show (default: 15)")
    args = parser.parse_args()

    try:
        if args.logfile == '-':
            stats = parse_log(sys.stdin, args.threshold)
        else:
            with open(args.logfile, 'r', encoding='utf-8', errors='replace') as f:
                stats = parse_log(f, args.threshold)
    except FileNotFoundError:
        print(f"Error: Log file not found: {args.logfile}", file=sys.stderr)
        sys.exit(1)

    print_report(stats, top_n=args.top, threshold_ms=args.threshold)


if __name__ == '__main__':
    main()