import { LightningElement, api, wire } from 'lwc';
import { getRecord, getFieldValue, notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';

import updateOpportunityStage from '@salesforce/apex/OpportunityPipelineController.updateOpportunityStage';

import STAGE_FIELD          from '@salesforce/schema/Opportunity.StageName';
import PIPELINE_GROUP_FIELD from '@salesforce/schema/Opportunity.Pipeline_Group__c';

const OPP_FIELDS = [STAGE_FIELD, PIPELINE_GROUP_FIELD];

/* ----------------------------------------------------------------
 *  PIPELINE CONFIGURATION
 *  --------------------------------------------------------------
 *  To add / move / reorder stages, edit STAGE_GROUPS below — that
 *  is the single source of truth for the visual pipeline.
 *  Make sure each `stages` value matches an active StageName API
 *  name in OpportunityStage.standardValueSet.
 *  ---------------------------------------------------------------- */
const STAGE_GROUPS = [
    {
        name: 'SOM',
        icon: 'utility:event',
        stages: [
            'SOM Ready',
            'SOM Link Sent',
            'SOM Scheduled',
            'SOM Completed',
            'Proposal Sent',
            'Contract Sent',
            'Enrollment Pending',
            'Enrollment Pending - Extended',
            'Contract Signed'
        ]
    },
    {
        name: 'Billing',
        icon: 'utility:money',
        stages: [
            'In Program',
            'Paused - Not Delinquent',
            'In Legal - Not Suspended',
            'Suspended - Delinquent',
            'Suspended - In Legal',
            'Terminated',
            'Terminated - MBG'
        ]
    },
    {
        name: 'FSS',
        icon: 'utility:contract',
        triggersClose: true,    // last stage → opens Won/Lost modal
        stages: [
            'FSS Onboarding',
            'FSS Scheduled',
            'FSS In Progress',
            'FSS Completed'
        ]
    }
];

const MERGED_CLOSED = '__CLOSED__';
const CLOSED_WON   = 'Closed Won';
const CLOSED_LOST  = 'Closed Lost';

/** Min pixel width per stage tile. Below this, the path overflows and scroll
 *  arrows appear. Tune up to give labels more room, down to fit more stages. */
const MIN_STAGE_WIDTH_PX = 160;

export default class OpportunityPipeline extends LightningElement {
    @api recordId;

    isLoading      = false;
    error          = null;
    selectedStage  = null;
    selectedType   = null;
    showCloseModal = false;

    _wiredRecord;
    currentStage = null;
    currentGroup = null;

    // Path overflow / scroll-arrow visibility (per track)
    mainCanScrollLeft  = false;
    mainCanScrollRight = false;
    subCanScrollLeft   = false;
    subCanScrollRight  = false;
    _observedTracks    = new WeakSet();

    @wire(getRecord, { recordId: '$recordId', fields: OPP_FIELDS })
    wiredRecord(result) {
        this._wiredRecord = result;
        if (result.data) {
            const wiredStage = getFieldValue(result.data, STAGE_FIELD);
            const wiredGroup = getFieldValue(result.data, PIPELINE_GROUP_FIELD);
            // Guard against a stale cached wire response overwriting a fresh
            // optimistic update. Only accept the wire once it confirms the
            // pending stage; otherwise keep the optimistic state.
            if (this._pendingStage !== undefined && this._pendingStage !== null) {
                if (wiredStage === this._pendingStage) {
                    this._pendingStage = null;
                    this._pendingGroup = null;
                    if (this._pendingTimeout) clearTimeout(this._pendingTimeout);
                } else {
                    return;
                }
            }
            this.currentStage = wiredStage;
            this.currentGroup = wiredGroup;
            this.error = null;
            this._clearSelection();
        } else if (result.error) {
            this.error = 'Error loading opportunity. Please refresh.';
        }
    }

    // ───────────────────────────────────────
    //  COMPUTED
    // ───────────────────────────────────────

    get isDataReady() { return this.currentStage !== null; }

    get _isClosed() {
        return this.currentStage === CLOSED_WON || this.currentStage === CLOSED_LOST;
    }

    /** Group containing the current StageName (or fallback when closed). */
    get _activeGroup() {
        if (this._isClosed) {
            return STAGE_GROUPS.find(g => g.triggersClose) || STAGE_GROUPS[0];
        }
        if (this.currentGroup) {
            const byField = STAGE_GROUPS.find(g => g.name === this.currentGroup);
            if (byField) return byField;
        }
        return STAGE_GROUPS.find(g => g.stages.includes(this.currentStage)) || STAGE_GROUPS[0];
    }

    get _activeIndex() {
        return STAGE_GROUPS.findIndex(g => g.name === this._activeGroup.name);
    }

    // ── Main pipeline ──
    get displayMainStages() {
        const closedLabel =
            this.currentStage === CLOSED_WON  ? 'Closed Won'  :
            this.currentStage === CLOSED_LOST ? 'Closed Lost' : 'Closed';
        return [
            ...STAGE_GROUPS.map(g => ({ value: g.name, label: g.name })),
            { value: MERGED_CLOSED, label: closedLabel }
        ];
    }

    get mainCurrentStep() {
        return this._isClosed ? MERGED_CLOSED : this._activeGroup.name;
    }

    // ── Sub pipeline ──
    get displaySubStages() {
        const g = this._activeGroup;
        const base = g.stages.map(v => ({ value: v, label: v }));
        if (!g.triggersClose) return base;
        const closedLabel =
            this.currentStage === CLOSED_WON  ? 'Closed Won'  :
            this.currentStage === CLOSED_LOST ? 'Closed Lost' : 'Closed';
        base.push({ value: MERGED_CLOSED, label: closedLabel });
        return base;
    }

    get _subStageValues() { return this.displaySubStages.map(s => s.value); }

    get subCurrentStep() {
        if (this._activeGroup.triggersClose && this._isClosed) return MERGED_CLOSED;
        return this.currentStage;
    }

    get subPipelineTitle() { return `${this._activeGroup.name} Stages`; }
    get subPipelineIcon()  { return this._activeGroup.icon || 'utility:activity'; }
    get subCardClass()     { return 'sub-pipeline-card'; }

    /** Hidden once the opportunity reaches Closed Won or Closed Lost — both
     *  are terminal, with nothing actionable at the sub-stage level. */
    get showSubPipeline()  { return !this._isClosed; }

    // ── Next steps ──
    get _subNextStep() {
        if (this.currentStage === CLOSED_LOST) return null;
        const values = this._subStageValues;
        const idx = values.indexOf(this.subCurrentStep);
        if (idx < 0) return values.length > 0 ? values[0] : null;
        return idx >= values.length - 1 ? null : values[idx + 1];
    }

    get _mainNextStep() {
        const idx = this._activeIndex;
        if (idx < 0 || idx >= STAGE_GROUPS.length - 1) return null;
        const next = STAGE_GROUPS[idx + 1];
        return next.stages.length > 0 ? next.stages[0] : null;
    }
    get _mainNextGroup() {
        const idx = this._activeIndex;
        if (idx < 0 || idx >= STAGE_GROUPS.length - 1) return null;
        return STAGE_GROUPS[idx + 1].name;
    }

    /** First stage of the group AFTER the close-trigger group (target of Closed Won chain). */
    get _afterCloseTriggerFirstStage() {
        const idx = STAGE_GROUPS.findIndex(g => g.triggersClose);
        if (idx < 0 || idx >= STAGE_GROUPS.length - 1) return null;
        const next = STAGE_GROUPS[idx + 1];
        return next.stages.length > 0 ? next.stages[0] : null;
    }
    get _afterCloseTriggerGroup() {
        const idx = STAGE_GROUPS.findIndex(g => g.triggersClose);
        if (idx < 0 || idx >= STAGE_GROUPS.length - 1) return null;
        return STAGE_GROUPS[idx + 1].name;
    }

    get isSubAtEnd() {
        if (this.currentStage === CLOSED_LOST) return true;
        return this._subNextStep === null && this._mainNextStep === null;
    }
    get isMainAtEnd() {
        return this._mainNextStep === null;
    }

    get mainActionDisabled() {
        // Closed Won / Closed Lost are terminal — no further main-path action.
        if (this._isClosed) return true;
        if (this.selectedStage && this.selectedType === 'main') {
            return this.selectedStage === MERGED_CLOSED;
        }
        return this.isMainAtEnd;
    }
    get mainActionLabel() {
        if (this._isClosed) return 'Complete';
        if (this.selectedStage && this.selectedType === 'main') return 'Move to Selected Group';
        return this.isMainAtEnd ? 'Complete' : 'Mark Group Complete';
    }
    get subActionDisabled() {
        if (this._isClosed) return true;
        if (this.selectedStage && this.selectedType === 'sub') return false;
        return this.isSubAtEnd;
    }
    get subActionLabel() {
        if (this.selectedStage && this.selectedType === 'sub') return 'Mark as Current Stage';
        return this.isSubAtEnd ? 'Complete' : 'Mark as Complete';
    }

    get mainPathStyle() {
        return `min-width: ${this.displayMainStages.length * MIN_STAGE_WIDTH_PX}px;`;
    }
    get subPathStyle() {
        return `min-width: ${this.displaySubStages.length * MIN_STAGE_WIDTH_PX}px;`;
    }

    // ───────────────────────────────────────
    //  HANDLERS
    // ───────────────────────────────────────

    handleStageClick(event) {
        const clicked = event.currentTarget.dataset.stage;
        const type    = event.currentTarget.dataset.type;
        if (!clicked || !type) return;
        if (type === 'main' && clicked === MERGED_CLOSED) return;

        const currentMap = { main: this.mainCurrentStep, sub: this.subCurrentStep };
        if (clicked === currentMap[type]) { this._clearSelection(); return; }

        if (this.selectedStage === clicked && this.selectedType === type) {
            this._clearSelection();
        } else {
            this.selectedStage = clicked;
            this.selectedType  = type;
        }
    }

    handleMainAction() {
        let targetStage, targetGroup;
        if (this.selectedStage && this.selectedType === 'main') {
            const g = STAGE_GROUPS.find(x => x.name === this.selectedStage);
            if (!g || g.stages.length === 0) return;
            targetStage = g.stages[0];
            targetGroup = g.name;
        } else {
            targetStage = this._mainNextStep;
            targetGroup = this._mainNextGroup;
        }
        if (!targetStage) return;

        // Leaving the close-trigger group → must capture Won/Lost first
        if (this._activeGroup.triggersClose &&
            this.currentStage !== CLOSED_WON &&
            targetGroup === this._afterCloseTriggerGroup) {
            this._openCloseModal();
            return;
        }
        this._call({ stageName: targetStage, pipelineGroup: targetGroup });
    }

    handleSubAction() {
        let targetStage = null;
        let targetGroup = this._activeGroup.name;

        if (this.selectedStage && this.selectedType === 'sub') {
            targetStage = this.selectedStage;
        } else {
            let next = this._subNextStep;
            // Skip the last stage of a non-close-trigger group: a single
            // click then jumps directly to the next group's first stage.
            if (next && !this._activeGroup.triggersClose && this._mainNextStep) {
                const stages = this._activeGroup.stages;
                const lastRaw = stages.length > 0 ? stages[stages.length - 1] : null;
                if (next === lastRaw) next = null;
            }
            if (next) {
                targetStage = next;
            } else if (this._mainNextStep) {
                targetStage = this._mainNextStep;
                targetGroup = this._mainNextGroup;
            }
        }
        if (targetStage === MERGED_CLOSED) { this._openCloseModal(); return; }
        if (!targetStage) return;

        this._call({ stageName: targetStage, pipelineGroup: targetGroup });
    }

    handleClosedWon() {
        this.showCloseModal = false;
        this._call({
            stageName: CLOSED_WON,
            pipelineGroup: this._activeGroup.name,
            advanceToStageName: this._afterCloseTriggerFirstStage,
            advanceToPipelineGroup: this._afterCloseTriggerGroup
        });
    }
    handleClosedLost() {
        this.showCloseModal = false;
        this._call({ stageName: CLOSED_LOST, pipelineGroup: this._activeGroup.name });
    }
    handleCloseModal() { this.showCloseModal = false; }

    handleScrollLeft(event)  { this._scrollPath(event.currentTarget.dataset.track, -1); }
    handleScrollRight(event) { this._scrollPath(event.currentTarget.dataset.track, +1); }

    _scrollPath(track, direction) {
        const el = this.template.querySelector(`.path-scroll[data-track="${track}"]`);
        if (!el) return;
        const delta = Math.max(160, Math.floor(el.clientWidth * 0.7)) * direction;
        el.scrollBy({ left: delta, behavior: 'smooth' });
    }

    // ───────────────────────────────────────
    //  LIFECYCLE
    // ───────────────────────────────────────

    connectedCallback() {
        this._onWindowResize = () => this._updateConnectorPosition();
        window.addEventListener('resize', this._onWindowResize, { passive: true });
    }

    /** Run after each render to attach overflow observers to any new path
     *  tracks and to re-position the sub-path connector under the active
     *  main-path stage. */
    renderedCallback() {
        const els = this.template.querySelectorAll('.path-scroll');
        els.forEach(el => {
            if (this._observedTracks.has(el)) return;
            this._observedTracks.add(el);
            this._attachScrollWatcher(el);
            window.requestAnimationFrame(() => {
                this._updateScrollFlags(el);
                this._updateConnectorPosition();
            });
        });
        window.requestAnimationFrame(() => this._updateConnectorPosition());
    }

    /** Tear down observers and listeners to prevent memory leaks. */
    disconnectedCallback() {
        if (this._resizeObservers) {
            this._resizeObservers.forEach(ro => ro.disconnect());
            this._resizeObservers = null;
        }
        if (this._onWindowResize) {
            window.removeEventListener('resize', this._onWindowResize);
            this._onWindowResize = null;
        }
    }

    _attachScrollWatcher(el) {
        el.addEventListener('scroll', () => this._updateScrollFlags(el), { passive: true });
        if (typeof ResizeObserver !== 'undefined') {
            const ro = new ResizeObserver(() => this._updateScrollFlags(el));
            ro.observe(el);
            if (!this._resizeObservers) this._resizeObservers = [];
            this._resizeObservers.push(ro);
        }
    }

    _updateScrollFlags(el) {
        const track = el.dataset.track;
        const canLeft  = el.scrollLeft > 0;
        const canRight = el.scrollLeft + el.clientWidth < el.scrollWidth - 1;
        if (track === 'main') {
            this.mainCanScrollLeft  = canLeft;
            this.mainCanScrollRight = canRight;
            this._updateConnectorPosition();
        } else if (track === 'sub') {
            this.subCanScrollLeft  = canLeft;
            this.subCanScrollRight = canRight;
        }
    }

    /** Position the sub-path connector under the active main-path stage. */
    _updateConnectorPosition() {
        if (!this.showSubPipeline) return;
        const subSection = this.template.querySelector('.sub-pipeline-section');
        if (!subSection) return;
        const activeStep = this.template.querySelector(
            `lightning-progress-step[data-type="main"][data-stage="${this.mainCurrentStep}"]`
        );
        if (!activeStep) return;
        const stepRect    = activeStep.getBoundingClientRect();
        const sectionRect = subSection.getBoundingClientRect();
        const offset = stepRect.left + stepRect.width / 2 - sectionRect.left;
        subSection.style.setProperty('--connector-left', `${offset}px`);
    }

    // ───────────────────────────────────────
    //  PRIVATE
    // ───────────────────────────────────────

    async _call(params) {
        this.isLoading = true;
        try {
            const updated = await updateOpportunityStage({ opportunityId: this.recordId, ...params });
            if (updated) {
                this.currentStage = updated.StageName;
                this.currentGroup = updated.Pipeline_Group__c;
                // Mark this as the pending optimistic state. The wired record
                // callback ignores stale wire responses until it sees a result
                // matching this state. Cleared after 3s as a safety net.
                this._pendingStage = updated.StageName;
                this._pendingGroup = updated.Pipeline_Group__c;
                if (this._pendingTimeout) clearTimeout(this._pendingTimeout);
                this._pendingTimeout = setTimeout(() => {
                    this._pendingStage = null;
                    this._pendingGroup = null;
                }, 3000);
            }
            this._clearSelection();
            this._showToast('Success', 'Stage updated successfully.', 'success');
            notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
            refreshApex(this._wiredRecord);
        } catch (err) {
            this._showError(err, 'An error occurred.');
        } finally {
            this.isLoading = false;
        }
    }

    _openCloseModal() { this.showCloseModal = true; }
    _clearSelection() { this.selectedStage = null; this.selectedType = null; }

    _showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
    _showError(err, fallback) {
        let msg = err?.body?.message || fallback;
        const vr = msg.match(/FIELD_CUSTOM_VALIDATION_EXCEPTION,\s*(.+?)(?::\s*\[|$)/);
        if (vr && vr[1]) msg = vr[1].trim();
        this._showToast('Error', msg, 'error');
    }
}
