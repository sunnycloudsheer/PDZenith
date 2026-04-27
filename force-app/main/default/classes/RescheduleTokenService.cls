public without sharing class RescheduleTokenService {

    private static final String BOOKING_BASE_URL =
        'https://site-enterprise-6958--dev2.sandbox.my.site.com/booking';

    private static final Set<String> TERMINAL_STATUSES = new Set<String>{
        'Canceled', 'Cannot Complete', 'Completed'
    };

    public static String generateToken() {
        Blob random = Crypto.generateAesKey(256);
        return EncodingUtil.convertToHex(random);
    }

    // CancellationReason is a restricted picklist; if the supplied value is not in the
    // picklist Salesforce throws INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST. Try the user value
    // first, then fall back to a generic value, then to whatever string was passed in.
    public static void tryPutCancellationReason(ServiceAppointment sa, String reasonText) {
        List<String> attempts = new List<String>{
            reasonText,
            'Customer Request',
            'Other',
            'Cancelled by Customer'
        };
        for (String attempt : attempts) {
            if (String.isBlank(attempt)) continue;
            try { sa.put('CancellationReason', attempt); return; } catch (Exception e) { }
        }
    }

    @AuraEnabled
    public static Map<String, Object> validateAndGetAppointment(String token) {
        Map<String, Object> result = new Map<String, Object>();
        if (String.isBlank(token)) {
            result.put('valid', false);
            result.put('error', 'This link is missing required information.');
            return result;
        }
        try {
            List<ServiceAppointment> sas = [
                SELECT Id, Status, SchedStartTime, SchedEndTime, Subject,
                       Meeting_Type__c, OwnerId, Owner.Name,
                       Admission_Counselor__c, Admission_Counselor__r.Name,
                       Program_Director__c, Program_Director__r.Name,
                       Family_Success_Specialist__c, Family_Success_Specialist__r.Name,
                       ContactId, AccountId, ParentRecordId
                FROM ServiceAppointment
                WHERE Reschedule_Token__c = :token
                LIMIT 1
            ];
            if (sas.isEmpty()) {
                result.put('valid', false);
                result.put('error', 'This link has expired or already been used.');
                return result;
            }
            ServiceAppointment sa = sas[0];
            if (TERMINAL_STATUSES.contains(sa.Status)) {
                result.put('valid', false);
                result.put('error', 'This link has expired or already been used.');
                return result;
            }
            if (sa.SchedStartTime != null && sa.SchedStartTime < DateTime.now().addHours(-1)) {
                result.put('valid', false);
                result.put('error', 'This appointment has already passed.');
                return result;
            }

            result.put('valid', true);
            result.put('appointmentId', sa.Id);
            result.put('startTime', sa.SchedStartTime != null
                ? sa.SchedStartTime.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') : null);
            // Show the actually-assigned counselor (role-specific field) —
            // Owner can be a queue/admin set by Scheduler auto-assignment and
            // doesn't reflect who the family was booked with.
            String assignedName = null;
            String mtForName = (sa.Meeting_Type__c != null) ? sa.Meeting_Type__c : '';
            if (mtForName.startsWith('Program Director')
                && sa.Program_Director__r != null) {
                assignedName = sa.Program_Director__r.Name;
            } else if (mtForName.startsWith('FSS')
                && sa.Family_Success_Specialist__r != null) {
                assignedName = sa.Family_Success_Specialist__r.Name;
            } else if (sa.Admission_Counselor__r != null) {
                assignedName = sa.Admission_Counselor__r.Name;
            }
            if (String.isBlank(assignedName) && sa.Owner != null) {
                assignedName = sa.Owner.Name;
            }
            result.put('counselorName', assignedName != null ? assignedName : '');
            result.put('meetingType', sa.Meeting_Type__c);
            result.put('rescheduleBookingUrl',
                BOOKING_BASE_URL + '?token=' + token + '&action=reschedule');
            return result;
        } catch (Exception e) {
            result.put('valid', false);
            result.put('error', 'Unable to load appointment.');
            return result;
        }
    }

    @AuraEnabled
    public static Map<String, String> cancelAppointment(String token, String reason) {
        Map<String, String> result = new Map<String, String>();
        if (String.isBlank(token)) {
            result.put('success', 'false');
            result.put('error', 'This link is missing required information.');
            return result;
        }
        Savepoint sp = Database.setSavepoint();
        try {
            List<ServiceAppointment> sas = [
                SELECT Id, Status, Description, Reschedule_Token__c
                FROM ServiceAppointment
                WHERE Reschedule_Token__c = :token
                LIMIT 1
                FOR UPDATE
            ];
            if (sas.isEmpty()) {
                result.put('success', 'false');
                result.put('error', 'This link has expired or already been used.');
                return result;
            }
            ServiceAppointment sa = sas[0];
            if (TERMINAL_STATUSES.contains(sa.Status)) {
                result.put('success', 'false');
                result.put('error', 'This link has expired or already been used.');
                return result;
            }

            sa.Status = 'Canceled';
            String reasonText = String.isNotBlank(reason) ? reason : 'Not specified';
            String existingDesc = (sa.Description != null) ? (sa.Description + '\n') : '';
            sa.Description = existingDesc + 'Cancellation reason: ' + reasonText;
            // CancellationReason is required by a validation rule when Status = 'Canceled'.
            tryPutCancellationReason(sa, reasonText);
            sa.Reschedule_Token__c = null;
            update sa;

            result.put('success', 'true');
            result.put('appointmentId', sa.Id);
            return result;
        } catch (Exception e) {
            Database.rollback(sp);
            result.put('success', 'false');
            result.put('error', 'Unable to cancel: ' + e.getMessage());
            return result;
        }
    }
}
