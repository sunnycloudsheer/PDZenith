/**
 * ═══════════════════════════════════════════════════════════════
 * PDRoundRobinHandler
 * ═══════════════════════════════════════════════════════════════
 * Invocable Apex called at the START of the cloned Outbound
 * New Appointment Flow — before any OOTB screen components.
 *
 * Purpose:
 *   1. Check Opportunity.Assigned_PD__c (sticky)
 *   2. If null → weighted round-robin among active PD resources
 *   3. Dynamically discover the selected PD's ServiceTerritory,
 *      OperatingHours, WorkType, and WorkTypeGroup so OOTB
 *      Scheduler components can use them
 *
 * Discovery chain (fully dynamic — no hardcoded names):
 *   User (Profile = 'Program Director') → ServiceResource
 *     → ServiceTerritoryMember → ServiceTerritory
 *       → OperatingHours
 *       → ServiceTerritoryWorkType → WorkType
 *         → WorkTypeGroupMember → WorkTypeGroup
 *
 * Called from: Clone of "Outbound New Appointment" Screen Flow
 * ═══════════════════════════════════════════════════════════════
 */
public with sharing class PDRoundRobinHandler {

    private static final String PD_PROFILE_NAME = 'Program Director';

    // ─── Invocable Input ───
    public class PDRequest {
        @InvocableVariable(required=true label='Opportunity Id')
        public Id opportunityId;

        @InvocableVariable(required=true label='Is Follow-up Call')
        public Boolean isFollowUp;
    }

    // ─── Invocable Output ───
    public class PDResult {
        @InvocableVariable(label='Selected ServiceResource Id')
        public Id serviceResourceId;

        @InvocableVariable(label='Selected ServiceTerritory Id')
        public Id serviceTerritoryId;

        @InvocableVariable(label='WorkType Id')
        public Id workTypeId;

        @InvocableVariable(label='PD Name')
        public String pdName;

        @InvocableVariable(label='PD User Id')
        public Id pdUserId;

        @InvocableVariable(label='Is Sticky Assignment')
        public Boolean isSticky;

        @InvocableVariable(label='Success')
        public Boolean success;

        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }

    /**
     * Internal wrapper: holds everything discovered for a PD resource.
     */
    private class DiscoveredPD {
        Id serviceResourceId;
        String pdName;
        Id pdUserId;
        Id serviceTerritoryId;
        Id operatingHoursId;
        Id workTypeId;
        Boolean isSticky = false;
    }

    @InvocableMethod(
        label='Get PD Assignment (Round Robin or Sticky)'
        description='Determines which PD should handle this Opportunity. Uses sticky if already assigned, otherwise weighted round-robin. Dynamically discovers Territory, WorkType, etc.'
        category='Scheduling'
    )
    public static List<PDResult> getAssignedPD(List<PDRequest> requests) {
        List<PDResult> results = new List<PDResult>();

        for (PDRequest req : requests) {
            PDResult res = new PDResult();
            try {
                // ─── 1. Get Opportunity ───
                List<Opportunity> oppList = [
                    SELECT Id, Assigned_PD__c
                    FROM Opportunity
                    WHERE Id = :req.opportunityId
                    LIMIT 1
                ];
                if (oppList.isEmpty()) {
                    throw new AuraHandledException('Opportunity not found: ' + req.opportunityId);
                }
                Opportunity opp = oppList[0];

                Boolean followUp = (req.isFollowUp != null && req.isFollowUp);

                // ─── 2. Determine PD resource (sticky or round-robin) ───
                Id selectedResourceId;
                Boolean isSticky = false;

                if (opp.Assigned_PD__c != null) {
                    // Verify sticky resource is still active and linked to a PD-profile user
                    List<ServiceResource> stickyCheck = [
                        SELECT Id, RelatedRecordId FROM ServiceResource
                        WHERE Id = :opp.Assigned_PD__c
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
                            selectedResourceId = opp.Assigned_PD__c;
                            isSticky = true;
                        }
                    }
                }

                if (selectedResourceId == null) {
                    selectedResourceId = selectByWeightedRoundRobin();
                }

                // ─── 3. Dynamically discover everything from the resource ───
                DiscoveredPD discovered = discoverFromResource(selectedResourceId, followUp);
                discovered.isSticky = isSticky;

                // ─── 4. Build Result ───
                res.serviceResourceId = discovered.serviceResourceId;
                res.serviceTerritoryId = discovered.serviceTerritoryId;
                res.workTypeId = discovered.workTypeId;
                res.pdName = discovered.pdName;
                res.pdUserId = discovered.pdUserId;
                res.isSticky = discovered.isSticky;
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
     * discoverFromResource
     * ═══════════════════════════════════════════════════════════
     * Given a ServiceResource Id, dynamically walks the FSL object
     * graph to find:
     *   Resource → User (active check)
     *   Resource → TerritoryMember → Territory (active, has OH)
     *   Territory → OperatingHours
     *   Territory → WorkType (via multiple fallback strategies)
     *
     * This mirrors the GuestSchedulerController.discover() pattern
     * but scoped to a single PD resource.
     * ═══════════════════════════════════════════════════════════
     */
    private static DiscoveredPD discoverFromResource(Id resourceId, Boolean isFollowUp) {
        DiscoveredPD cfg = new DiscoveredPD();
        cfg.serviceResourceId = resourceId;

        // ─── Resource details ───
        List<ServiceResource> srList = [
            SELECT Id, Name, RelatedRecordId
            FROM ServiceResource
            WHERE Id = :resourceId
            AND IsActive = true
            LIMIT 1
        ];
        if (srList.isEmpty()) {
            throw new AuraHandledException(
                'Selected PD Service Resource is not active.'
            );
        }
        ServiceResource sr = srList[0];
        cfg.pdName = sr.Name;

        // ─── Verify related User is active with Program Director profile ───
        if (sr.RelatedRecordId == null) {
            throw new AuraHandledException(
                'Service Resource "' + sr.Name + '" has no related User.'
            );
        }
        List<User> userCheck = [
            SELECT Id FROM User
            WHERE Id = :sr.RelatedRecordId
            AND Profile.Name = :PD_PROFILE_NAME
            AND IsActive = true
            LIMIT 1
        ];
        if (userCheck.isEmpty()) {
            throw new AuraHandledException(
                'The related User for "' + sr.Name + '" does not have the Program Director profile or is inactive.'
            );
        }
        cfg.pdUserId = sr.RelatedRecordId;

        // ─── Territory: find best active territory for this resource ───
        Date today = Date.today();
        List<ServiceTerritoryMember> stmList = [
            SELECT ServiceTerritoryId, OperatingHoursId,
                   ServiceTerritory.OperatingHoursId,
                   ServiceTerritory.IsActive,
                   ServiceTerritory.Name
            FROM ServiceTerritoryMember
            WHERE ServiceResourceId = :sr.Id
            AND EffectiveStartDate <= :today
            AND (EffectiveEndDate = NULL OR EffectiveEndDate >= :today)
            AND ServiceTerritory.IsActive = true
            ORDER BY CreatedDate DESC
        ];
        if (stmList.isEmpty()) {
            throw new AuraHandledException(
                'No active Service Territory found for PD "' + sr.Name
                + '". Please assign this PD to a Service Territory with valid membership dates.'
            );
        }

        // ─── Pick the territory whose linked WorkType matches the duration ───
        // 60 min for First SOM Call, 30 min for Follow-up
        Integer targetDuration = isFollowUp ? 30 : 60;

        // Collect all territory Ids from memberships
        Set<Id> candidateTerritoryIds = new Set<Id>();
        Map<Id, ServiceTerritoryMember> stmByTerritoryId = new Map<Id, ServiceTerritoryMember>();
        for (ServiceTerritoryMember stm : stmList) {
            candidateTerritoryIds.add(stm.ServiceTerritoryId);
            if (!stmByTerritoryId.containsKey(stm.ServiceTerritoryId)) {
                stmByTerritoryId.put(stm.ServiceTerritoryId, stm);
            }
        }

        // Find which territories have a WorkType matching the target duration
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

        // Best match: territory with correct-duration WorkType + OperatingHours
        ServiceTerritoryMember bestStm = null;
        Id matchedWorkTypeId = null;

        // Priority 1: territory with matching WorkType duration and OperatingHours
        for (ServiceTerritoryMember stm : stmList) {
            if (territoryToWorkType.containsKey(stm.ServiceTerritoryId)
                && (stm.ServiceTerritory.OperatingHoursId != null || stm.OperatingHoursId != null)) {
                bestStm = stm;
                matchedWorkTypeId = territoryToWorkType.get(stm.ServiceTerritoryId);
                break;
            }
        }

        // Priority 2: territory with matching WorkType duration (no OH requirement)
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

        cfg.serviceTerritoryId = bestStm.ServiceTerritoryId;

        // Resolve OperatingHours: territory-level first, then member-level
        if (bestStm.ServiceTerritory.OperatingHoursId != null) {
            cfg.operatingHoursId = bestStm.ServiceTerritory.OperatingHoursId;
        } else if (bestStm.OperatingHoursId != null) {
            cfg.operatingHoursId = bestStm.OperatingHoursId;
        }

        // ─── WorkType: use matched WorkType if found, otherwise discover ───
        if (matchedWorkTypeId != null) {
            cfg.workTypeId = matchedWorkTypeId;
        } else {
            cfg.workTypeId = discoverWorkType(isFollowUp, cfg.serviceTerritoryId, cfg.operatingHoursId);
        }
        if (cfg.workTypeId == null) {
            throw new AuraHandledException(
                'No Work Type found for territory "'
                + bestStm.ServiceTerritory.Name
                + '". Please create a Work Type and link it to the Service Territory or its Operating Hours.'
            );
        }

        return cfg;
    }

    /**
     * ═══════════════════════════════════════════════════════════
     * discoverWorkType  (multi-step fallback)
     * ═══════════════════════════════════════════════════════════
     * Tries multiple strategies to find the right WorkType,
     * modelled after GuestSchedulerController.discover():
     *
     *   1. Exact name match (PD SOM Meeting - 1hr / PD Follow-up - 30min)
     *   2. ServiceTerritoryWorkType linked to the territory
     *      – if follow-up, prefer shorter duration; else prefer longer
     *   3. WorkType linked to the territory's OperatingHours
     *   4. Name pattern match (%PD%, %SOM%, %Follow%)
     *   5. Last resort: any WorkType in the org
     * ═══════════════════════════════════════════════════════════
     */
    private static Id discoverWorkType(Boolean isFollowUp, Id territoryId, Id operatingHoursId) {

        // Known names (tried first, but not required to exist)
        String preferredName = isFollowUp
            ? 'PD Follow-up - 30min'
            : 'PD SOM Meeting - 1hr';

        // ── Step 1: Exact name ──
        List<WorkType> exactMatch = [
            SELECT Id FROM WorkType
            WHERE Name = :preferredName
            LIMIT 1
        ];
        if (!exactMatch.isEmpty()) {
            return exactMatch[0].Id;
        }

        // ── Step 2: ServiceTerritoryWorkType on the territory ──
        if (territoryId != null) {
            try {
                List<ServiceTerritoryWorkType> stwts = [
                    SELECT WorkTypeId, WorkType.DurationInMinutes, WorkType.Name
                    FROM ServiceTerritoryWorkType
                    WHERE ServiceTerritoryId = :territoryId
                    ORDER BY WorkType.DurationInMinutes ASC
                ];
                if (!stwts.isEmpty()) {
                    if (isFollowUp) {
                        return stwts[0].WorkTypeId;
                    } else {
                        return stwts[stwts.size() - 1].WorkTypeId;
                    }
                }
            } catch (Exception e) {
                // ServiceTerritoryWorkType may not be available in all orgs
            }
        }

        // ── Step 3: WorkType linked to OperatingHours ──
        if (operatingHoursId != null) {
            List<WorkType> wtByOH = [
                SELECT Id, DurationInMinutes FROM WorkType
                WHERE OperatingHoursId = :operatingHoursId
                ORDER BY DurationInMinutes DESC
            ];
            if (!wtByOH.isEmpty()) {
                if (isFollowUp) {
                    return wtByOH[wtByOH.size() - 1].Id;
                } else {
                    return wtByOH[0].Id;
                }
            }
        }

        // ── Step 4: Name pattern match ──
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

        // Also try generic PD pattern
        List<WorkType> pdPattern = [
            SELECT Id FROM WorkType
            WHERE Name LIKE '%PD%'
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        if (!pdPattern.isEmpty()) {
            return pdPattern[0].Id;
        }

        // ── Step 5: Last resort — any WorkType ──
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

    /**
     * ═══════════════════════════════════════════════════════════
     * selectByWeightedRoundRobin
     * ═══════════════════════════════════════════════════════════
     * Weighted Round-Robin:
     *   Effective Load = Appointment_Count__c / Weight__c
     *   Selects the PD with the LOWEST effective load.
     *
     *   Only considers resources that:
     *     - Are linked to an active User with Program Director profile
     *     - Are active
     *     - Have at least one active territory membership
     * ═══════════════════════════════════════════════════════════
     */
    private static Id selectByWeightedRoundRobin() {
        // Step 1: Find active Users with Program Director profile
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

        // Step 2: Find active ServiceResources linked to those Users
        List<ServiceResource> pdResources = [
            SELECT Id, Appointment_Count__c, Weight__c, RelatedRecordId
            FROM ServiceResource
            WHERE RelatedRecordId IN :pdUserIds
            AND IsActive = true
            ORDER BY CreatedDate ASC
        ];

        if (pdResources.isEmpty()) {
            throw new AuraHandledException(
                'No active Service Resources found for Program Director users. '
                + 'Please create Service Resources for PD users.'
            );
        }

        // Step 3: Filter to resources that have active territory memberships
        Set<Id> allSrIds = new Set<Id>();
        for (ServiceResource sr : pdResources) {
            allSrIds.add(sr.Id);
        }

        Date today = Date.today();
        Set<Id> resourcesWithTerritory = new Set<Id>();
        for (ServiceTerritoryMember stm : [
            SELECT ServiceResourceId
            FROM ServiceTerritoryMember
            WHERE ServiceResourceId IN :allSrIds
            AND EffectiveStartDate <= :today
            AND (EffectiveEndDate = NULL OR EffectiveEndDate >= :today)
            AND ServiceTerritory.IsActive = true
        ]) {
            resourcesWithTerritory.add(stm.ServiceResourceId);
        }

        // Filter: has territory
        List<ServiceResource> validResources = new List<ServiceResource>();
        for (ServiceResource sr : pdResources) {
            if (resourcesWithTerritory.contains(sr.Id)) {
                validResources.add(sr);
            }
        }

        if (validResources.isEmpty()) {
            throw new AuraHandledException(
                'No fully configured PD Service Resources found. '
                + 'Each PD needs: an active User with Program Director profile, '
                + 'an active Service Resource, and an active Service Territory membership.'
            );
        }

        // Weighted round-robin selection
        Id bestId = null;
        Decimal bestLoad = null;

        for (ServiceResource sr : validResources) {
            Decimal count = (sr.Appointment_Count__c != null) ? sr.Appointment_Count__c : 0;
            Decimal weight = (sr.Weight__c != null && sr.Weight__c > 0) ? sr.Weight__c : 1.0;
            Decimal effectiveLoad = count / weight;

            if (bestLoad == null || effectiveLoad < bestLoad) {
                bestLoad = effectiveLoad;
                bestId = sr.Id;
            }
        }

        return bestId;
    }
}