/**
 * ═══════════════════════════════════════════════════════════════
 * PDSchedulingConfigHandler
 * ═══════════════════════════════════════════════════════════════
 * Invocable Apex called at the START of the PD Book SOM Call flow
 * — BEFORE the time-slot selection screen.
 *
 * Purpose:
 *   Returns the shared ServiceTerritory and WorkType that ALL
 *   active PDs belong to, so the OOTB flowTimeslot component
 *   can display combined availability across every PD.
 *
 *   NO PD is assigned here. Assignment happens AFTER the user
 *   selects a time slot and the ServiceAppointment is created,
 *   via PDPostBookingHandler (weighted round-robin).
 *
 * Discovery chain (fully dynamic — no hardcoded names):
 *   User (Profile = 'Program Director') → ServiceResource
 *     → ServiceTerritoryMember → ServiceTerritory
 *       → OperatingHours
 *       → ServiceTerritoryWorkType → WorkType
 *
 * Called from: PD: Book SOM Call (Screen Flow)
 * ═══════════════════════════════════════════════════════════════
 */
public with sharing class PDSchedulingConfigHandler {

    private static final String PD_PROFILE_NAME = 'Program Director';

    public class ConfigRequest {
        @InvocableVariable(required=true label='Opportunity Id')
        public Id opportunityId;

        @InvocableVariable(required=true label='Is Follow-up Call')
        public Boolean isFollowUp;
    }

    public class ConfigResult {
        @InvocableVariable(label='ServiceTerritory Id')
        public Id serviceTerritoryId;

        @InvocableVariable(label='WorkType Id')
        public Id workTypeId;

        @InvocableVariable(label='Primary ServiceResource Id')
        public Id primaryResourceId;

        @InvocableVariable(label='All PD Resource Ids (comma-separated)')
        public String allResourceIds;

        @InvocableVariable(label='Success')
        public Boolean success;

        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }

    @InvocableMethod(
        label='Get PD Scheduling Config (All PDs)'
        description='Returns shared territory and work type for ALL PDs. No PD assignment — that happens after booking.'
        category='Scheduling'
    )
    public static List<ConfigResult> getSchedulingConfig(List<ConfigRequest> requests) {
        List<ConfigResult> results = new List<ConfigResult>();

        for (ConfigRequest req : requests) {
            ConfigResult res = new ConfigResult();
            try {
                Boolean followUp = (req.isFollowUp != null && req.isFollowUp);

                // ─── 0. Check for sticky PD on follow-up calls ───
                // If this is a follow-up and the Opp already has an assigned PD,
                // show ONLY that PD's time slots (not all PDs).
                Id stickyResourceId = null;
                if (followUp) {
                    List<Opportunity> oppList = [
                        SELECT Id, Assigned_PD__c FROM Opportunity
                        WHERE Id = :req.opportunityId LIMIT 1
                    ];
                    if (!oppList.isEmpty() && oppList[0].Assigned_PD__c != null) {
                        // Verify the sticky PD is still active with PD profile
                        List<ServiceResource> stickyCheck = [
                            SELECT Id, RelatedRecordId FROM ServiceResource
                            WHERE Id = :oppList[0].Assigned_PD__c
                            AND IsActive = true
                            LIMIT 1
                        ];
                        if (!stickyCheck.isEmpty() && stickyCheck[0].RelatedRecordId != null) {
                            List<User> pdUser = [
                                SELECT Id FROM User
                                WHERE Id = :stickyCheck[0].RelatedRecordId
                                AND Profile.Name = :PD_PROFILE_NAME
                                AND IsActive = true
                                LIMIT 1
                            ];
                            if (!pdUser.isEmpty()) {
                                stickyResourceId = oppList[0].Assigned_PD__c;
                            }
                        }
                    }
                }

                // ─── 1. Find PD resources ───
                // If sticky PD found → use only that resource
                // Otherwise → find all active PD resources
                Set<Id> srIds = new Set<Id>();
                List<Id> srIdList = new List<Id>();

                if (stickyResourceId != null) {
                    srIds.add(stickyResourceId);
                    srIdList.add(stickyResourceId);
                } else {
                    Set<Id> pdUserIds = new Set<Id>();
                    for (User u : [
                        SELECT Id FROM User
                        WHERE Profile.Name = :PD_PROFILE_NAME
                        AND IsActive = true
                    ]) {
                        pdUserIds.add(u.Id);
                    }
                    if (pdUserIds.isEmpty()) {
                        throw new AuraHandledException(
                            'No active users found with the Program Director profile.'
                        );
                    }

                    for (ServiceResource sr : [
                        SELECT Id FROM ServiceResource
                        WHERE RelatedRecordId IN :pdUserIds
                        AND IsActive = true
                        ORDER BY CreatedDate ASC
                    ]) {
                        srIds.add(sr.Id);
                        srIdList.add(sr.Id);
                    }
                    if (srIds.isEmpty()) {
                        throw new AuraHandledException(
                            'No active Service Resources found for Program Director users.'
                        );
                    }
                }

                // ─── 3. Find active territories for these resources ───
                Date today = Date.today();
                List<ServiceTerritoryMember> stmList = [
                    SELECT ServiceTerritoryId, ServiceResourceId, OperatingHoursId,
                           ServiceTerritory.OperatingHoursId,
                           ServiceTerritory.IsActive,
                           ServiceTerritory.Name
                    FROM ServiceTerritoryMember
                    WHERE ServiceResourceId IN :srIds
                    AND EffectiveStartDate <= :today
                    AND (EffectiveEndDate = NULL OR EffectiveEndDate >= :today)
                    AND ServiceTerritory.IsActive = true
                    ORDER BY CreatedDate DESC
                ];
                if (stmList.isEmpty()) {
                    throw new AuraHandledException(
                        'No active Service Territory found for any Program Director. '
                        + 'Please assign PD resources to a Service Territory with valid membership dates.'
                    );
                }

                // ─── 4. Pick the best territory (WorkType match + OperatingHours) ───
                Integer targetDuration = followUp ? 30 : 60;

                Set<Id> candidateTerritoryIds = new Set<Id>();
                for (ServiceTerritoryMember stm : stmList) {
                    candidateTerritoryIds.add(stm.ServiceTerritoryId);
                }

                Map<Id, Id> territoryToWorkType = new Map<Id, Id>();
                try {
                    for (ServiceTerritoryWorkType stwt : [
                        SELECT ServiceTerritoryId, WorkTypeId, WorkType.DurationInMinutes
                        FROM ServiceTerritoryWorkType
                        WHERE ServiceTerritoryId IN :candidateTerritoryIds
                    ]) {
                        if (stwt.WorkType.DurationInMinutes == targetDuration) {
                            territoryToWorkType.put(stwt.ServiceTerritoryId, stwt.WorkTypeId);
                        }
                    }
                } catch (Exception e) {
                    // ServiceTerritoryWorkType may not be available in all orgs
                }

                ServiceTerritoryMember bestStm = null;
                Id matchedWorkTypeId = null;

                // Priority 1: territory with matching WorkType + OperatingHours
                for (ServiceTerritoryMember stm : stmList) {
                    if (territoryToWorkType.containsKey(stm.ServiceTerritoryId)
                        && (stm.ServiceTerritory.OperatingHoursId != null || stm.OperatingHoursId != null)) {
                        bestStm = stm;
                        matchedWorkTypeId = territoryToWorkType.get(stm.ServiceTerritoryId);
                        break;
                    }
                }
                // Priority 2: territory with matching WorkType (no OH requirement)
                if (bestStm == null) {
                    for (ServiceTerritoryMember stm : stmList) {
                        if (territoryToWorkType.containsKey(stm.ServiceTerritoryId)) {
                            bestStm = stm;
                            matchedWorkTypeId = territoryToWorkType.get(stm.ServiceTerritoryId);
                            break;
                        }
                    }
                }
                // Priority 3: any territory with OperatingHours
                if (bestStm == null) {
                    for (ServiceTerritoryMember stm : stmList) {
                        if (stm.ServiceTerritory.OperatingHoursId != null || stm.OperatingHoursId != null) {
                            bestStm = stm;
                            break;
                        }
                    }
                }
                // Priority 4: first available territory
                if (bestStm == null) {
                    bestStm = stmList[0];
                }

                Id operatingHoursId = bestStm.ServiceTerritory.OperatingHoursId != null
                    ? bestStm.ServiceTerritory.OperatingHoursId
                    : bestStm.OperatingHoursId;

                // ─── 5. Resolve WorkType ───
                Id workTypeId = matchedWorkTypeId;
                if (workTypeId == null) {
                    workTypeId = discoverWorkType(followUp, bestStm.ServiceTerritoryId, operatingHoursId);
                }
                if (workTypeId == null) {
                    throw new AuraHandledException(
                        'No Work Type found for territory "'
                        + bestStm.ServiceTerritory.Name
                        + '". Please create a Work Type and link it to the Service Territory.'
                    );
                }

                // ─── 6. Collect only resources that belong to the selected territory ───
                Id selectedTerritoryId = bestStm.ServiceTerritoryId;
                List<Id> territoryResourceIds = new List<Id>();
                Set<Id> seenResourceIds = new Set<Id>();
                for (ServiceTerritoryMember stm : stmList) {
                    if (stm.ServiceTerritoryId == selectedTerritoryId
                        && !seenResourceIds.contains(stm.ServiceResourceId)) {
                        territoryResourceIds.add(stm.ServiceResourceId);
                        seenResourceIds.add(stm.ServiceResourceId);
                    }
                }
                if (territoryResourceIds.isEmpty()) {
                    throw new AuraHandledException(
                        'No PD resources found in territory "'
                        + bestStm.ServiceTerritory.Name + '".'
                    );
                }

                res.serviceTerritoryId = selectedTerritoryId;
                res.workTypeId = workTypeId;
                res.primaryResourceId = territoryResourceIds[0];
                res.allResourceIds = String.join(territoryResourceIds, ',');
                res.success = true;

            } catch (Exception e) {
                res.success = false;
                res.errorMessage = e.getMessage();
            }
            results.add(res);
        }
        return results;
    }

    /**
     * ═══════════════════════════════════════════════════════════
     * discoverWorkType  (multi-step fallback)
     * ═══════════════════════════════════════════════════════════
     */
    private static Id discoverWorkType(Boolean isFollowUp, Id territoryId, Id operatingHoursId) {

        String preferredName = isFollowUp
            ? 'PD Follow-up - 30min'
            : 'PD SOM Meeting - 1hr';

        // Step 1: Exact name
        List<WorkType> exactMatch = [
            SELECT Id FROM WorkType
            WHERE Name = :preferredName
            LIMIT 1
        ];
        if (!exactMatch.isEmpty()) {
            return exactMatch[0].Id;
        }

        // Step 2: ServiceTerritoryWorkType on the territory
        if (territoryId != null) {
            try {
                List<ServiceTerritoryWorkType> stwts = [
                    SELECT WorkTypeId, WorkType.DurationInMinutes
                    FROM ServiceTerritoryWorkType
                    WHERE ServiceTerritoryId = :territoryId
                    ORDER BY WorkType.DurationInMinutes ASC
                ];
                if (!stwts.isEmpty()) {
                    return isFollowUp ? stwts[0].WorkTypeId : stwts[stwts.size() - 1].WorkTypeId;
                }
            } catch (Exception e) { }
        }

        // Step 3: WorkType linked to OperatingHours
        if (operatingHoursId != null) {
            List<WorkType> wtByOH = [
                SELECT Id, DurationInMinutes FROM WorkType
                WHERE OperatingHoursId = :operatingHoursId
                ORDER BY DurationInMinutes DESC
            ];
            if (!wtByOH.isEmpty()) {
                return isFollowUp ? wtByOH[wtByOH.size() - 1].Id : wtByOH[0].Id;
            }
        }

        // Step 4: Name pattern match
        String likePattern = isFollowUp ? '%Follow%' : '%SOM%';
        List<WorkType> patternMatch = [
            SELECT Id FROM WorkType
            WHERE Name LIKE :likePattern
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        if (!patternMatch.isEmpty()) {
            return patternMatch[0].Id;
        }

        List<WorkType> pdPattern = [
            SELECT Id FROM WorkType
            WHERE Name LIKE '%PD%'
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        if (!pdPattern.isEmpty()) {
            return pdPattern[0].Id;
        }

        // Step 5: Last resort — any WorkType
        List<WorkType> anyWT = [
            SELECT Id FROM WorkType
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        if (!anyWT.isEmpty()) {
            return anyWT[0].Id;
        }

        return null;
    }
}
