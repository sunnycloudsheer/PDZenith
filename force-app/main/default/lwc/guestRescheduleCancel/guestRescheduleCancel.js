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
    @track isCancelling = false;

    get showOtherReason() {
        return this.cancelReason === 'Other';
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

                // Format the date/time for display
                if (result.startTime) {
                    const dt = new Date(result.startTime);
                    this.formattedDateTime = dt.toLocaleDateString('en-US', {
                        weekday: 'long',
                        month: 'long',
                        day: 'numeric',
                        year: 'numeric'
                    }) + ' at ' + dt.toLocaleTimeString('en-US', {
                        hour: 'numeric',
                        minute: '2-digit',
                        hour12: true
                    });
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
        if (this.cancelReason !== 'Other') {
            this.otherReason = '';
        }
    }

    handleOtherReasonChange(event) {
        this.otherReason = event.target.value;
    }

    async handleConfirmCancel() {
        // Validate
        if (!this.cancelReason) {
            this.cancelError = 'Please select a reason for cancellation.';
            return;
        }
        if (this.cancelReason === 'Other' && !this.otherReason.trim()) {
            this.cancelError = 'Please specify your reason.';
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