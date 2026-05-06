// Centralized resolver for the Experience Cloud booking site URL; queries SiteDetail once per transaction and caches.
public without sharing class BookingUrlConfig {

    private static final String BOOKING_PATH_PREFIX = 'booking';
    private static String cachedBaseUrl;

    // Returns the full Experience Cloud booking URL (e.g. https://foo.my.site.com/booking) for the current org.
    public static String getBookingBaseUrl() {
        if (cachedBaseUrl != null) return cachedBaseUrl;
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
        // Fallback when SiteDetail isn't queryable (e.g. permission gap or test context).
        cachedBaseUrl = URL.getOrgDomainUrl().toExternalForm()
            .replace('.my.salesforce.com', '.my.site.com') + '/' + BOOKING_PATH_PREFIX;
        return cachedBaseUrl;
    }
}
