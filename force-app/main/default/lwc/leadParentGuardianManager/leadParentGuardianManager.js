import { LightningElement, api, wire, track } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { getRecordNotifyChange } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { CloseActionScreenEvent } from 'lightning/actions';

import getParents from '@salesforce/apex/LeadFamilyController.getParents';
import saveParent from '@salesforce/apex/LeadFamilyController.saveParent';
import deleteParent from '@salesforce/apex/LeadFamilyController.deleteParent';
import ensurePrimaryParentId from '@salesforce/apex/LeadFamilyController.ensurePrimaryParentId';

const ROLE_SECOND = 'Second';
const BLANK_FORM = Object.freeze({
    type: 'Parent',
    firstName: '',
    lastName: '',
    email: '',
    phone: ''
});
const TYPE_OPTIONS = [
    { label: 'Parent', value: 'Parent' },
    { label: 'Guardian', value: 'Guardian' }
];

export default class LeadParentGuardianManager extends LightningElement {
    @api recordId;
    // Retained for backwards compatibility — see leadStudentManager.js for context.
    @api sectionTitle;
    @api openOnLoad = false;

    @track data;
    @track form = { ...BLANK_FORM };

    isModalOpen = false;
    isEditMode = false;
    isLoading = false;
    isSaving = false;

    _wired;
    // Set once we kick off ensurePrimaryParentId so refreshApex'd wire data
    // doesn't re-trigger the call in a loop.
    _primaryIdEnsured = false;

    connectedCallback() {
        // Bust LDS cache on mount in case the record was just updated via
        // Apex / a trigger and the cached snapshot is stale.
        if (this.recordId) {
            getRecordNotifyChange([{ recordId: this.recordId }]);
        }
    }

    @wire(getParents, { leadId: '$recordId' })
    wiredParents(result) {
        this._wired = result;
        if (result.data) {
            this.data = result.data;
            // If the primary parent doesn't have an ID yet, ask the server to
            // generate + persist one. Guarded by _primaryIdEnsured so the
            // refreshApex this triggers doesn't loop us back here.
            if (!this._primaryIdEnsured && result.data.primary && !result.data.primary.parentId) {
                this._primaryIdEnsured = true;
                this.ensurePrimaryId();
            }
            if (this.openOnLoad && !this.isAddDisabled) {
                this.openOnLoad = false;
                this.handleOpenAdd();
            }
        } else if (result.error) {
            // eslint-disable-next-line no-console
            console.error('LeadParentGuardianManager getParents error:', result.error);
            this.showToast('Error', this.extractError(result.error), 'error');
        }
    }

    async ensurePrimaryId() {
        try {
            await ensurePrimaryParentId({ leadId: this.recordId });
            await refreshApex(this._wired);
        } catch (err) {
            // eslint-disable-next-line no-console
            console.error('LeadParentGuardianManager ensurePrimaryParentId error:', err);
            // Non-fatal: the ID will be generated on the next save anyway.
        }
    }

    get typeOptions() {
        return TYPE_OPTIONS;
    }

    // ─── Derived ──────────────────────────────────────────
    get primary() {
        return this.data?.primary;
    }

    get second() {
        return this.data?.second;
    }

    get primaryPopulated() {
        return this.primary?.populated === true;
    }

    get secondPopulated() {
        return this.second?.populated === true;
    }

    get hasAdults() {
        return this.primaryPopulated || this.secondPopulated;
    }

    get primaryEmailDisplay() {
        return this.primary?.email || '—';
    }

    get primaryPhoneDisplay() {
        return this.primary?.phone || '—';
    }

    get secondEmailDisplay() {
        return this.second?.email || '—';
    }

    get secondPhoneDisplay() {
        return this.second?.phone || '—';
    }

    get isAddDisabled() {
        return this.isLoading || this.secondPopulated;
    }

    get modalTitle() {
        return this.isEditMode ? 'Edit Parent / Guardian' : 'Add Parent / Guardian';
    }

    // ─── Modal ────────────────────────────────────────────
    handleOpenAdd() {
        if (this.isAddDisabled) return;
        this.isEditMode = false;
        this.form = { ...BLANK_FORM };
        this.isModalOpen = true;
    }

    handleOpenEdit() {
        if (!this.secondPopulated) return;
        const a = this.second;
        this.isEditMode = true;
        this.form = {
            type: a.type || 'Parent',
            firstName: a.firstName || '',
            lastName: a.lastName || '',
            email: a.email || '',
            phone: a.phone || ''
        };
        this.isModalOpen = true;
    }

    handleCloseModal() {
        this.isModalOpen = false;
    }

    handleInput(event) {
        const { name, value } = event.target;
        this.form = { ...this.form, [name]: value };
    }

    async handleSave() {
        if (!this.validateForm()) return;
        this.isSaving = true;
        try {
            const { type, firstName, lastName, email, phone } = this.form;
            await saveParent({
                leadId: this.recordId,
                role: ROLE_SECOND,
                adultType: type,
                firstName,
                lastName,
                email,
                phone
            });
            await refreshApex(this._wired);
            getRecordNotifyChange([{ recordId: this.recordId }]);
            this.isModalOpen = false;
            this.showToast('Saved', `${type} saved.`, 'success');
            this.dispatchEvent(new CloseActionScreenEvent());
        } catch (err) {
            this.showToast('Error', this.extractError(err), 'error');
        } finally {
            this.isSaving = false;
        }
    }

    async handleDelete() {
        // eslint-disable-next-line no-alert
        if (!window.confirm('Remove second adult?')) return;
        this.isLoading = true;
        try {
            await deleteParent({ leadId: this.recordId, role: ROLE_SECOND });
            await refreshApex(this._wired);
            getRecordNotifyChange([{ recordId: this.recordId }]);
            this.showToast('Removed', 'Second adult removed.', 'success');
        } catch (err) {
            this.showToast('Error', this.extractError(err), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    // ─── Helpers ──────────────────────────────────────────
    /**
     * Phone is optional (empty is OK), but if entered must contain at least
     * 10 digits. Catches "----------" / "(   )" garbage that satisfies the
     * HTML pattern attribute but isn't a usable number.
     */
    validatePhone() {
        const el = this.template.querySelector('lightning-input[name="phone"]');
        if (!el) return true;
        const v = (el.value || '').trim();
        if (!v) {
            el.setCustomValidity('');
            return true;
        }
        const digits = v.replace(/\D/g, '');
        if (digits.length < 10) {
            el.setCustomValidity('Please enter a valid phone number.');
            el.reportValidity();
            return false;
        }
        el.setCustomValidity('');
        return true;
    }

    validateForm() {
        const phoneOk = this.validatePhone();
        const inputs = [
            ...this.template.querySelectorAll('lightning-input'),
            ...this.template.querySelectorAll('lightning-radio-group')
        ];
        const otherOk = inputs.reduce((valid, el) => {
            el.reportValidity();
            return valid && el.checkValidity();
        }, true);
        return phoneOk && otherOk;
    }

    extractError(err) {
        // eslint-disable-next-line no-console
        console.error('LeadParentGuardianManager error:', err);
        if (!err) return 'Unknown error.';
        if (typeof err === 'string') return err;

        if (err.body?.message) return err.body.message;

        if (err.body?.pageErrors?.length) {
            return err.body.pageErrors.map(e => e.message).join(', ');
        }

        if (err.body?.fieldErrors && typeof err.body.fieldErrors === 'object') {
            const msgs = [];
            for (const k of Object.keys(err.body.fieldErrors)) {
                const list = err.body.fieldErrors[k];
                if (Array.isArray(list)) msgs.push(...list.map(e => e.message));
            }
            if (msgs.length) return msgs.join(', ');
        }

        if (err.body?.output?.errors?.length) {
            return err.body.output.errors.map(e => e.message).join(', ');
        }

        if (Array.isArray(err.body)) {
            const msgs = err.body.map(b => b?.message).filter(Boolean);
            if (msgs.length) return msgs.join(', ');
        }

        if (err.message) return err.message;

        try {
            return JSON.stringify(err.body || err);
        } catch (e) {
            return 'Unknown error.';
        }
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
