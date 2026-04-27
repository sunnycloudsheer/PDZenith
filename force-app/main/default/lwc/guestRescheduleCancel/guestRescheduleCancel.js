import { LightningElement, track } from 'lwc';
import validateAndGetAppointment from '@salesforce/apex/GuestSchedulerController.validateAppointmentByToken';
import cancelAppointment from '@salesforce/apex/GuestSchedulerController.cancelAppointmentByToken';

export default class GuestRescheduleCancel extends LightningElement {

    @track isLoading = true;
    @track isReady = false;
    @track hasError = false;
    @track errorTitle = '';
    @track errorMessage = '';

    // Appointment data
    token = '';
    appointmentId = '';
    @track formattedDateTime = '';
    @track counselorName = '';
    @track rescheduleBookingUrl = '';
    meetingType = '';

    // View states
    @track showAppointmentDetails = false;
    @track showActions = false;
    @track showCancelForm = false;
    @track showCancelSuccess = false;

    // Cancel form
    @track cancelReason = '';
    @track otherReason = '';
    @track cancelError = '';
    @track reasonError = '';
    @track otherReasonError = '';
    @track isCancelling = false;

    get showOtherReason() {
        return this.cancelReason === 'Other';
    }

    get reasonSelectClass() {
        return this.reasonError ? 'field-inp field-inp-error' : 'field-inp';
    }

    get otherReasonInputClass() {
        return this.otherReasonError ? 'field-inp field-inp-error' : 'field-inp';
    }

    get counselorInitials() {
        if (!this.counselorName) return '';
        const parts = this.counselorName.trim().split(/\s+/);
        const first = parts[0] ? parts[0].charAt(0) : '';
        const last = parts.length > 1 ? parts[parts.length - 1].charAt(0) : '';
        return (first + last).toUpperCase();
    }

    connectedCallback() {
        this._extractToken();
        if (this.token) {
            this._validateToken();
        } else {
            this.errorTitle = 'Invalid Link';
            this.errorMessage = 'This link is missing required information. Please use the link from your confirmation email.';
            this.hasError = true;
            this.isLoading = false;
        }
    }

    _extractToken() {
        try {
            const params = new URLSearchParams(window.location.search);
            this.token = params.get('token') || '';
            this._action = (params.get('action') || '').toLowerCase();
        } catch (e) {
            this.token = '';
            this._action = '';
        }
    }

    async _validateToken() {
        try {
            const result = await validateAndGetAppointment({ token: this.token });

            if (result.valid) {
                this.appointmentId = result.appointmentId;
                this.counselorName = result.counselorName || '';
                this.meetingType = result.meetingType || '';
                this.rescheduleBookingUrl = result.rescheduleBookingUrl || '';

                // Format the date/time for display — short style:
                // "Tue, Apr 28 · 9:15 PM"
                if (result.startTime) {
                    const dt = new Date(result.startTime);
                    const datePart = dt.toLocaleDateString('en-US', {
                        weekday: 'short',
                        month: 'short',
                        day: 'numeric'
                    });
                    const timePart = dt.toLocaleTimeString('en-US', {
                        hour: 'numeric',
                        minute: '2-digit',
                        hour12: true
                    });
                    this.formattedDateTime = `${datePart} · ${timePart}`;
                }

                this.showAppointmentDetails = true;
                this.showActions = true;
                this.isReady = true;

                // Cancel mode: jump straight to the cancel form
                if (window.location.pathname.includes('/cancel') || this._action === 'cancel') {
                    this.handleCancelClick();
                }
            } else {
                const reason = (result.error || '').toLowerCase();
                const linkExpired = reason.includes('expired') || reason.includes('already');
                if (linkExpired) {
                    if (this._action === 'cancel') {
                        this.errorTitle = 'Meeting Already Canceled';
                        this.errorMessage = 'This appointment has already been canceled. Please contact us if you need to book a new one.';
                    } else if (this._action === 'reschedule') {
                        this.errorTitle = 'Meeting Already Rescheduled';
                        this.errorMessage = 'This appointment has already been rescheduled or canceled. Please contact us if you need further changes.';
                    } else {
                        this.errorTitle = 'Meeting Already Scheduled';
                        this.errorMessage = 'This scheduling link has already been used. Please contact us if you need to reschedule.';
                    }
                } else {
                    this.errorTitle = 'Link Issue';
                    this.errorMessage = result.error || 'Unable to find this appointment.';
                }
                this.hasError = true;
            }
        } catch (err) {
            this.errorTitle = 'Something went wrong';
            this.errorMessage = err?.body?.message || err?.message || 'Unable to verify your appointment.';
            this.hasError = true;
        } finally {
            this.isLoading = false;
        }
    }

    handleCancelClick() {
        this.showActions = false;
        this.showCancelForm = true;
        this.cancelError = '';
    }

    handleBackToDetails() {
        this.showCancelForm = false;
        this.showActions = true;
        this.cancelError = '';
    }

    handleReasonChange(event) {
        this.cancelReason = event.target.value;
        // Clear field-specific error as soon as the user picks a value.
        if (this.cancelReason) {
            this.reasonError = '';
        }
        if (this.cancelReason !== 'Other') {
            this.otherReason = '';
            this.otherReasonError = '';
        }
    }

    handleOtherReasonChange(event) {
        this.otherReason = event.target.value;
        if (this.otherReason && this.otherReason.trim()) {
            this.otherReasonError = '';
        }
    }

    async handleConfirmCancel() {
        // Validate — collect ALL field errors before bailing so the user
        // sees every problem at once instead of one-at-a-time.
        let hasError = false;
        if (!this.cancelReason) {
            this.reasonError = 'Please select a reason for cancellation.';
            hasError = true;
        } else {
            this.reasonError = '';
        }
        if (this.cancelReason === 'Other' && !this.otherReason.trim()) {
            this.otherReasonError = 'Please specify your reason.';
            hasError = true;
        } else {
            this.otherReasonError = '';
        }
        if (hasError) {
            // Keep the bottom-of-form general error clear — field-specific
            // errors render inline next to the offending input.
            this.cancelError = '';
            return;
        }

        this.cancelError = '';
        this.isCancelling = true;

        const reason = this.cancelReason === 'Other'
            ? `Other: ${this.otherReason.trim()}`
            : this.cancelReason;

        try {
            const result = await cancelAppointment({
                token: this.token,
                reason: reason
            });

            if (result.success === 'true') {
                this.showCancelForm = false;
                this.showAppointmentDetails = false;
                this.showCancelSuccess = true;
            } else {
                this.cancelError = result.error || 'Unable to cancel. Please try again.';
            }
        } catch (err) {
            this.cancelError = err?.body?.message || err?.message || 'An error occurred.';
        } finally {
            this.isCancelling = false;
        }
    }
}