namespace DigitalRewards.Core;

/// <summary>Resolves IANA time zone ids on every platform.</summary>
public static class TimeZones
{
    public static TimeZoneInfo Find(string id)
    {
        if (TryFind(id, out var zone))
        {
            return zone;
        }
        throw new TimeZoneNotFoundException($"Unknown time zone '{id}'.");
    }

    public static bool TryFind(string? id, out TimeZoneInfo zone)
    {
        zone = TimeZoneInfo.Utc;
        if (string.IsNullOrWhiteSpace(id))
        {
            return false;
        }
        try
        {
            zone = TimeZoneInfo.FindSystemTimeZoneById(id);
            return true;
        }
        catch (Exception e) when (e is TimeZoneNotFoundException or InvalidTimeZoneException)
        {
        }
        if (TimeZoneInfo.TryConvertIanaIdToWindowsId(id, out var windowsId))
        {
            try
            {
                zone = TimeZoneInfo.FindSystemTimeZoneById(windowsId);
                return true;
            }
            catch (Exception e) when (e is TimeZoneNotFoundException or InvalidTimeZoneException)
            {
            }
        }
        return false;
    }
}
