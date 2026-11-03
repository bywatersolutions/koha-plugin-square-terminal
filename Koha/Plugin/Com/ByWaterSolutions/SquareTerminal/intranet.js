$(document).ready(function() {

    function ensureSquareModal() {
        if ($('#squareModal').length) return;

            $('body').append(`
          <style>
            .square-processing-wrap {
              display: flex;
              flex-direction: column;
              align-items: center;
              justify-content: center;
              gap: 0.75rem;
              min-height: 120px;
              text-align: center;
            }

            .square-processing-spinner {
              width: 2rem;
              height: 2rem;
              border: 0.25rem solid #d1d5db;
              border-top-color: #0d6efd;
              border-radius: 50%;
              animation: square-spin 0.8s linear infinite;
            }

            @keyframes square-spin {
              to { transform: rotate(360deg); }
            }
          </style>

          <div class="modal fade" id="squareModal" role="dialog" aria-hidden="true">
            <div class="modal-dialog">
              <div class="modal-content">
                <div class="modal-header">
                  <h4 class="modal-title">Square Terminal processing</h4>
                </div>
                <div id="squareModalBody" class="modal-body">
                  <div class="square-processing-wrap">
                    <div class="square-processing-spinner" aria-hidden="true"></div>
                    <div id="squareStatusText" aria-live="polite">
                      Processing payment... Please follow prompts on the Square Terminal.
                    </div>
                  </div>
                </div>
                <div class="modal-footer">
                  <button id="square-cancel" type="button" class="btn btn-default">Cancel</button>
                </div>
              </div>
            </div>
          </div>
        `);
        }

    function renderSquareButton(id, label) {
        return `<input style="margin-left: 5px" type="button"
                       id="${id}"
                       name="${id}"
                       value="${label}"
                       class="submit btn btn-primary">`;
    }

    function parseAmountToCents(amount) {
    if (amount == null) return null;

    const normalized = String(amount)
        .trim()
        .replace(/[$,]/g, '');

    if (!/^\d+(\.\d{1,2})?$/.test(normalized)) {
        console.log('Invalid Square amount:', {
            original: amount,
            normalized: normalized,
            characters: Array.from(String(amount)).map(char => char.charCodeAt(0))
        });

        return null;
    }

    const cents = Math.round(Number(normalized) * 100);

    return Number.isSafeInteger(cents) && cents > 0
        ? cents
        : null;
}

    function launchSquarePayment(accountlineIds, defaultAmount, registerId) {
        if (!accountlineIds || !accountlineIds.length) {
            alert("No charges selected.");
            return;
        }

        const accountlines = encodeURIComponent(accountlineIds.join(","));
        const debitUrl = `/api/v1/contrib/square_terminal/get_debits/${accountlines}`;

        $.getJSON(debitUrl, function(data) {
            const suggestedAmount = defaultAmount || data.total;
            let amount = prompt("Enter amount to collect", suggestedAmount);
            if (amount == null) return;

            const amountCents = parseAmountToCents(amount);
            if (amountCents == null) {
                alert(`The amount "${amount}" is invalid. Please specify as a currency format (e.g. 1.00)`);
                return;
            }

            const registerParam = registerId
                ? `&register_id=${encodeURIComponent(registerId)}`
                : '';

            const createUrl = `/api/v1/contrib/square_terminal/checkout/${accountlines}?amount=${encodeURIComponent(amountCents)}${registerParam}`;

            $.ajax({
                url: createUrl,
                method: 'POST',
                dataType: 'json',
                success: function(resp) {
                    const checkoutId = resp.checkout_id;
                    if (!checkoutId) {
                        alert("ERROR: Missing checkout_id from server");
                        return;
                    }

                    $('#squareStatusText').text('Processing payment... Please follow prompts on the Square Terminal.');
                    const squareModalEl = document.getElementById('squareModal');
                    const squareModal = bootstrap.Modal.getOrCreateInstance(squareModalEl, {
                            backdrop: 'static',
                            keyboard: false
                    });
                    squareModal.show();

                    const statusUrl = `/api/v1/contrib/square_terminal/checkout/status/${encodeURIComponent(checkoutId)}`;

                    let pollCount = 0;

                                        let pollTimer = setInterval(function() {
                        pollCount++;

                        $.getJSON(statusUrl, function(statusResp) {
                            const checkout = statusResp.checkout || {};
                            const status = checkout.status || statusResp.status || '';

                            console.log("Square checkout status:", statusResp?.checkout?.status);
                            console.log("Full Square checkout response:", JSON.stringify(statusResp, null, 2));

                            let friendlyStatus = status || 'UNKNOWN';
                            if (status === 'PENDING') {
                                friendlyStatus = 'Square payment is processing... Waiting for customer on terminal.';
                            } else if (status === 'IN_PROGRESS') {
                                friendlyStatus = 'Square payment is processing... Customer is interacting with terminal.';
                            } else if (status === 'COMPLETED') {
                                friendlyStatus = 'Payment complete!';
                            }

                            $('#squareStatusText').text(friendlyStatus);

                            if (status === 'CANCELED' || status === 'CANCELLED' || status === 'FAILED') {
                                clearInterval(pollTimer);
                                bootstrap.Modal.getOrCreateInstance(document.getElementById('squareModal')).hide();

                                const dismissUrl = `/api/v1/contrib/square_terminal/checkout/dismiss/${encodeURIComponent(checkoutId)}`;
                                $.ajax({ url: dismissUrl, method: 'POST' });

                                alert("Transaction canceled or failed.");
                                return;
                            }

                            if (status === 'COMPLETED') {
                                clearInterval(pollTimer);

                                const checkoutRegisterId = resp.register_id || registerId;
                                const registerParam = checkoutRegisterId
                                    ? `?register_id=${encodeURIComponent(checkoutRegisterId)}`
                                    : '';

                                const finalizeUrl = `/api/v1/contrib/square_terminal/checkout/finalize/${encodeURIComponent(checkoutId)}/${accountlines}${registerParam}`;

                                $.ajax({
                                    url: finalizeUrl,
                                    method: 'POST',
                                    dataType: 'json',
                                    success: function(finalizeResp) {
                                        bootstrap.Modal.getOrCreateInstance(document.getElementById('squareModal')).hide();

                                        const dismissUrl = `/api/v1/contrib/square_terminal/checkout/dismiss/${encodeURIComponent(checkoutId)}`;
                                        $.ajax({ url: dismissUrl, method: 'POST' });

                                        const paymentId = finalizeResp.payment_id;

                                        $('#pay-via-square-individual, #pay-selected-via-square')
                                            .prop('disabled', true);

                                        const currentUrl = new URL(window.location.href);
                                        const borrowernumber = currentUrl.searchParams.get('borrowernumber');

                                        const accountUrl = borrowernumber
                                            ? `/cgi-bin/koha/members/boraccount.pl?borrowernumber=${encodeURIComponent(borrowernumber)}`
                                            : window.location.href;

                                        const openReceipt = paymentId && window.confirm(
                                                "Payment completed successfully.\n\nWould you like to open the receipt?"
                                            );

                                        if (openReceipt) {
                                            const receiptUrl =
                                                `/cgi-bin/koha/members/printfeercpt.pl?action=print&accountlines_id=${encodeURIComponent(paymentId)}`;

                                            window.open(receiptUrl, '_blank');
                                        }
                                        window.location.href = accountUrl;
                                    },
                                    error: function(xhr) {
                                        bootstrap.Modal.getOrCreateInstance(document.getElementById('squareModal')).hide();
                                        alert("ERROR finalizing payment in Koha: " + (xhr.responseText || xhr.statusText));
                                    }
                                });

                                return;
                            }

                            if (pollCount >= 60) {
                                clearInterval(pollTimer);
                                bootstrap.Modal.getOrCreateInstance(document.getElementById('squareModal')).hide();

                                alert(`Square checkout timed out. Last status: ${status || 'UNKNOWN'}`);

                                const dismissUrl = `/api/v1/contrib/square_terminal/checkout/dismiss/${encodeURIComponent(checkoutId)}`;
                                $.ajax({ url: dismissUrl, method: 'POST' });

                                return;
                            }
                        });
                    }, 1000);

                    $('#square-cancel').off('click').on('click', function() {
                        clearInterval(pollTimer);

                        const dismissUrl = `/api/v1/contrib/square_terminal/checkout/dismiss/${encodeURIComponent(checkoutId)}`;
                        $.ajax({
                            url: dismissUrl,
                            method: 'POST',
                            complete: function() {
                                bootstrap.Modal.getOrCreateInstance(document.getElementById('squareModal')).hide();
                            }
                        });
                    });
                },

                error: function(xhr) {
    console.log("checkout error xhr", xhr);
    let msg = "ERROR creating Square checkout";
    try {
        const j = xhr.responseJSON || JSON.parse(xhr.responseText);
        if (j && (j.description || j.error)) {
            msg = `${j.error || 'ERROR'}: ${j.description || ''}`;
        } else if (xhr.responseText) {
            msg = xhr.responseText;
        }
    } catch(e) {
        if (xhr.responseText) {
            msg = xhr.responseText;
        }
    }
    alert(msg);
                }
        });
    });
    }

function launchSquarePosPayment(defaultAmount, registerId) {
    if (!defaultAmount || defaultAmount === '0.00') {
        alert("No POS total found.");
        return;
    }

    if (!registerId) {
        alert("Please select a cash register.");
        return;
    }

    const amountCents = parseAmountToCents(defaultAmount);

    if (amountCents == null) {
        alert(
            `The amount "${defaultAmount}" is invalid. ` +
            'Please specify it as a currency format, such as 1.00.'
        );
        return;
    }

    const createUrl =
        `/api/v1/contrib/square_terminal/checkout/pos` +
        `?amount=${encodeURIComponent(amountCents)}` +
        `&register_id=${encodeURIComponent(registerId)}`;

        $.ajax({
            url: createUrl,
            method: 'POST',
            dataType: 'json',
            success: function(resp) {
                const checkoutId = resp.checkout_id;
                if (!checkoutId) {
                    alert("ERROR: Missing checkout_id from server");
                    return;
                }

                $('#squareStatusText').text('Square payment is processing... Please follow prompts on the Square Terminal.');
                const squareModalEl = document.getElementById('squareModal');
                const squareModal = bootstrap.Modal.getOrCreateInstance(squareModalEl, {
                    backdrop: 'static',
                    keyboard: false
                });
                squareModal.show();

                const statusUrl = `/api/v1/contrib/square_terminal/checkout/status/${encodeURIComponent(checkoutId)}`;
                let pollCount = 0;
                let paymentSubmitted = false;
                let checkoutCanceled = false;
                let pollingStopped = false;
                let pollTimer;

                const dismissCheckout = function() {
                    const dismissUrl =
                        `/api/v1/contrib/square_terminal/checkout/dismiss/${encodeURIComponent(checkoutId)}`;

                    $.ajax({
                        url: dismissUrl,
                        method: 'POST'
                    });
                };

                const closeSquareModal = function() {
                    bootstrap.Modal.getOrCreateInstance(
                        document.getElementById('squareModal')
                    ).hide();
                };

                pollTimer = setInterval(function() {
                    pollCount++;

                    if (pollCount >= 60) {
                        clearInterval(pollTimer);
                        pollingStopped = true;

                        if (!paymentSubmitted && !checkoutCanceled) {
                            closeSquareModal();
                            dismissCheckout();

                            alert(
                                "Square checkout timed out. " +
                                "Please verify the terminal before retrying."
                            );
                        }

                        return;
                    }

                    $.getJSON(statusUrl)
                        .done(function(statusResp) {
                            if (paymentSubmitted || checkoutCanceled || pollingStopped) {
                                return;
                            }

                            const checkout = statusResp.checkout || {};
                            const status = checkout.status || statusResp.status || '';

                            let friendlyStatus = status || 'UNKNOWN';

                            if (status === 'PENDING') {
                                friendlyStatus =
                                    'Square payment is processing... Waiting for customer on terminal.';
                            } else if (status === 'IN_PROGRESS') {
                                friendlyStatus =
                                    'Square payment is processing... Customer is interacting with terminal.';
                            } else if (status === 'COMPLETED') {
                                friendlyStatus = 'Payment complete!';
                            }

                            $('#squareStatusText').text(friendlyStatus);

                            if (
                                status === 'CANCELED' ||
                                status === 'CANCELLED' ||
                                status === 'FAILED'
                            ) {
                                clearInterval(pollTimer);
                                closeSquareModal();
                                dismissCheckout();

                                alert("Transaction canceled or failed.");
                                return;
                            }

                            if (status === 'COMPLETED') {
                                clearInterval(pollTimer);

                                // Verify the completed checkout amount.
                                const checkoutAmount =
                                    checkout.amount_money &&
                                    checkout.amount_money.amount;

                                if (
                                    !Number.isSafeInteger(Number(checkoutAmount)) ||
                                    Number(checkoutAmount) !== Number(amountCents)
                                ) {
                                    closeSquareModal();
                                    dismissCheckout();

                                    alert(
                                        "Square payment amount does not match " +
                                        "the requested POS amount. " +
                                        "Please verify the transaction before continuing."
                                    );
                                    return;
                                }

                                // Ensure the POS form is available.
                                const $payForm = $('#payForm');

                                if (!$payForm.length) {
                                    closeSquareModal();
                                    dismissCheckout();

                                    alert(
                                        "Unable to locate the Koha POS payment form. " +
                                        "Please verify the transaction."
                                    );
                                    return;
                                }

                                // Prevent duplicate submissions.
                                if (paymentSubmitted) {
                                    return;
                                }

                                paymentSubmitted = true;

                                dismissCheckout();
                                closeSquareModal();

                                // Make Koha treat the POS payment as a credit card payment.
                                $('#payment_type').val('CREDITCARD');

                                // Preserve Koha's normal POS workflow.
                                $payForm.trigger('submit');
                                return;
                            }
                        })
                        .fail(function(xhr) {
                            if (paymentSubmitted || checkoutCanceled || pollingStopped) {
                                return;
                            }

                            console.error(
                                "Square checkout status request failed:",
                                xhr
                            );

                            $('#squareStatusText').text(
                                'Unable to check Square payment status. Retrying...'
                            );
                        });

                }, 1000);

                $('#square-cancel').off('click').on('click', function() {
                    if (paymentSubmitted || checkoutCanceled || pollingStopped) {
                        return;
                    }

                    checkoutCanceled = true;
                    clearInterval(pollTimer);

                    const dismissUrl =
                        `/api/v1/contrib/square_terminal/checkout/dismiss/${encodeURIComponent(checkoutId)}`;

                    $.ajax({
                        url: dismissUrl,
                        method: 'POST',
                        complete: function() {
                            closeSquareModal();
                        }
                    });
                });
            },
            error: function(xhr) {
                console.log("checkout error xhr", xhr);
                let msg = "ERROR creating Square checkout";
                try {
                    const j = xhr.responseJSON || JSON.parse(xhr.responseText);
                    if (j && (j.description || j.error)) {
                        msg = `${j.error || 'ERROR'}: ${j.description || ''}`;
                    } else if (xhr.responseText) {
                        msg = xhr.responseText;
                    }
                } catch(e) {
                    if (xhr.responseText) {
                        msg = xhr.responseText;
                    }
                }
                alert(msg);
            }
        });
    }

    function initMakePaymentPage() {
        if (!$('#writeoff-selected').length || $('#pay-selected-via-square').length) return;

        const buttonHtml = renderSquareButton('pay-selected-via-square', 'Pay via Square');
        $(buttonHtml).insertAfter('#writeoff-selected');

        function selectedAccountlineIds() {
            let ids = [];
            $(".cb:checked").each(function() {
                const id = $(this).attr("name").split("_")[2];
                if (id) ids.push(id);
            });
            return ids;
        }

        function setButtonState() {
            if ($('.cb:checkbox:checked').length > 0) {
                $('#pay-selected-via-square').removeAttr("disabled");
            } else {
                $('#pay-selected-via-square').attr("disabled", "disabled");
            }
        }

        $('#pay-selected-via-square').attr("disabled", "disabled");
        setButtonState();
        $('.cb').on("change", setButtonState);

        $('#pay-selected-via-square').on('click', function(e) {
            e.preventDefault();
            launchSquarePayment(selectedAccountlineIds(), null, $('#cash_register').val());
        });
    }

    function initIndividualPaymentPage() {
        if (!$('#payindivfine').length || $('#pay-via-square-individual').length) return;

        const buttonHtml = renderSquareButton('pay-via-square-individual', 'Pay via Square');
        $(buttonHtml).insertAfter('#payindivfine .action input[type="submit"].btn.btn-primary');

        $('#pay-via-square-individual').on('click', function(e) {
            e.preventDefault();

            const accountlineId = $('#accountlines_id').val();
            const paid = $('#paid').val();

            if (!accountlineId) {
                alert("No accountline_id found on individual payment page.");
                return;
            }

            const registerId = $('#cash_register').val();

            if ($('#cash_register').length && !registerId) {
                alert("Please select a cash register.");
                return;
            }

            launchSquarePayment([accountlineId], paid, registerId);
        });
    }


        function initPosPage() {
        if (!$('#submitbutton').length || !$('#sale').length || $('#pay-via-square-pos').length) return;

        const buttonHtml = renderSquareButton('pay-via-square-pos', 'Pay via Square');
        $(buttonHtml).insertAfter('#submitbutton');

        $('#pay-via-square-pos').on('click', function(e) {
            e.preventDefault();

            const paid = $('#paid').val();
            const registerId = $('#registerid').val();

            if (!paid || paid === '0.00') {
                alert("No POS total found.");
                return;
            }

            if (!registerId) {
                alert("Please select a cash register.");
                return;
            }

            launchSquarePosPayment(paid, registerId);
        });
    }

    ensureSquareModal();
    initMakePaymentPage();
    initIndividualPaymentPage();
    initPosPage();
});
