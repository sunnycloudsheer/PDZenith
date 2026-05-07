// Issues reschedule/cancel tokens for ServiceAppointments and provides the public Aura endpoints used by the booking site to validate or cancel a meeting.
public without sharing class RescheduleTokenService {

    // Admin-editable per environment via Custom Label Booking_Site_Base_URL (host only, no path).
    private static final String BOOKING_BASE_URL =
        System.Label.Booking_Site_Base_URL.removeEnd('/') + '/booking';

    private static final Set<String> TERMINAL_STATUSES = new Set<String>{
        'Canceled', 'Cannot Complete', 'Completed'
    };

    // Generates a 256-bit random hex token (64 chars) used for SA reschedule + IC schedule URLs.
    public static String generateToken() {
        Blob random = Crypto.generateAesKey(256);
        return EncodingUtil.convertToHex(random);
    }

    // CancellationReason is a restricted picklist — try the supplied reason, then known fallback values.
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

    // Validates a reschedule token and returns the SA details + reschedule booking URL for the public site.
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
            // Prefer the assigned counselor over Owner — Owner can be a queue.
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

    // Cancels the SA tied to the given token, expires the Zoom meeting, and triggers the cancel-email flow.
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

            // Customer-facing cancel status fires the family-cancel rule in Meeting_After_RTF.
            sa.Status = 'Meeting Canceled by Customer';
            String reasonText = String.isNotBlank(reason) ? reason : 'Not specified';
            String existingDesc = (sa.Description != null) ? (sa.Description + '\n') : '';
            sa.Description = existingDesc + 'Cancellation reason: ' + reasonText;
            tryPutCancellationReason(sa, reasonText);
            sa.Reschedule_Token__c = null;
            try {
                update sa;
            } catch (DmlException de) {
                Boolean badPicklist = false;
                for (Integer i = 0; i < de.getNumDml(); i++) {
                    String code = String.valueOf(de.getDmlType(i));
                    if (code != null && (code.contains('PICKLIST')
                        || de.getDmlMessage(i) != null
                        && (de.getDmlMessage(i).contains('restricted picklist')
                            || de.getDmlMessage(i).contains('invalid value for restricted picklist')))) {
                        badPicklist = true;
                        break;
                    }
                }
                if (!badPicklist) throw de;
                // Fallback for orgs without the new picklist value.
                sa.Status = 'Meeting Canceled by Student';
                update sa;
            }

            // Async-delete the Zoom meeting so the join URL stops working.
            try {
                System.enqueueJob(new ZoomMeetingManager.ZoomCancelQueueable(
                    new Set<Id>{ sa.Id }
                ));
            } catch (Exception ex) {
                System.debug(LoggingLevel.WARN,
                    'cancelAppointment: failed to enqueue ZoomCancelQueueable for SA '
                    + sa.Id + ': ' + ex.getMessage());
            }

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