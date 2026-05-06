// Centralized resolver for the Experience Cloud booking site URL; reads Custom Label Booking_Site_Base_URL and caches per transaction.
public without sharing class BookingUrlConfig {

    private static final String BOOKING_PATH_PREFIX = 'booking';
    private static String cachedBaseUrl;

    // Returns the full booking URL (e.g. https://foo.my.site.com/booking). Primary source: Custom Label Booking_Site_Base_URL (admin-editable per environment); falls back to SiteDetail SOQL, then to URL.getOrgDomainUrl() transform.
    public static String getBookingBaseUrl() {
        if (cachedBaseUrl != null) return cachedBaseUrl;

        // Primary: Custom Label set by admin per environment (host only, no path).
        String labelValue;
        try { labelValue = System.Label.Booking_Site_Base_URL; } catch (Exception e) { /* ignore */ }
        if (String.isNotBlank(labelValue)) {
            cachedBaseUrl = labelValue.removeEnd('/') + '/' + BOOKING_PATH_PREFIX;
            return cachedBaseUrl;
        }

        // Fallback 1: query the active booking SiteDetail.
        try {
            List<Site> sites = [
                SELECT Id FROM Site
                WHERE UrlPathPrefix = :BOOKING_PATH_PREFIX AND Status = 'Active'
                LIMIT 1
            ];
            if (!sites.isEmpty()) {
                Id siteId = sites[0].Id;
                for (SiteDetail sd : [
                    SELECT SecureUrl FROM SiteDetail WHERE DurableId = :siteId LIMIT 1
                ]) {
                    if (String.isNotBlank(sd.SecureUrl)) {
                        cachedBaseUrl = sd.SecureUrl;
                        return cachedBaseUrl;
                    }
                }
            }
        } catch (Exception e) { /* fall through to derived URL */ }

        // Fallback 2: derive from the org's My Domain URL (.my.salesforce.com → .my.site.com).
        cachedBaseUrl = URL.getOrgDomainUrl().toExternalForm()
            .replace('.my.salesforce.com', '.my.site.com') + '/' + BOOKING_PATH_PREFIX;
        return cachedBaseUrl;
    }
}
