namespace DigitalRewards.Core;

/// <summary>Ledger entry kinds; declaration order is the tie-break sort order (CONTRACT §3).</summary>
public enum EntryKind
{
    Earn = 0,
    Adjust = 1,
    Spend = 2,
}

/// <param name="Minutes">Earn and spend are non-negative magnitudes; adjust is signed.</param>
/// <param name="At">Epoch milliseconds.</param>
public sealed record LedgerEntry(string Id, EntryKind Kind, int Minutes, long At)
{
    public int Delta => Kind == EntryKind.Spend ? -Minutes : Minutes;
}

/// <summary>Deterministic balance fold (CONTRACT §3).</summary>
public static class LedgerFold
{
    public static IEnumerable<LedgerEntry> Ordered(IEnumerable<LedgerEntry> entries) =>
        entries
            .OrderBy(e => e.At)
            .ThenBy(e => (int)e.Kind)
            .ThenBy(e => e.Id, StringComparer.Ordinal);

    public static int Balance(IEnumerable<LedgerEntry> entries, int? maxBank)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        long balance = 0;
        foreach (var e in Ordered(entries))
        {
            if (!seen.Add(e.Id))
            {
                continue;
            }
            long delta = e.Delta;
            if (delta > 0 && maxBank is { } cap)
            {
                balance = Math.Max(balance, Math.Min(balance + delta, cap));
            }
            else
            {
                balance += delta;
            }
        }
        return checked((int)balance);
    }
}
