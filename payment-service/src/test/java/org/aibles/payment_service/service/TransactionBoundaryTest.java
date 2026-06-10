package org.aibles.payment_service.service;

import org.junit.jupiter.api.Test;
import org.springframework.transaction.annotation.Transactional;

import java.lang.reflect.Method;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;

/**
 * Guards the call-then-record boundary: PayPal HTTP calls live in
 * PaymentServiceImpl and must NOT run inside a JTA transaction (Atomikos
 * maxActives=50 saturated when ~1.3s HTTP calls held tx slots — see
 * docs/performance-stress-report-2026-06-10.md P2). All DB writes live in
 * PaymentRecorder behind short @Transactional methods.
 */
class TransactionBoundaryTest {

    @Test
    void paymentServiceImpl_hasNoTransactionalMethods() {
        for (Method m : PaymentServiceImpl.class.getDeclaredMethods()) {
            assertNull(m.getAnnotation(Transactional.class),
                    "PaymentServiceImpl." + m.getName() + " must not be @Transactional"
                    + " (it performs HTTP I/O); writes belong in PaymentRecorder");
        }
        assertNull(PaymentServiceImpl.class.getAnnotation(Transactional.class));
    }

    @Test
    void paymentRecorder_writeMethodsAreTransactional() {
        Set<String> writeMethods = Set.of("recordPurchase", "recordSuccess", "recordCancel", "recordFailure");
        for (Method m : PaymentRecorder.class.getDeclaredMethods()) {
            if (writeMethods.contains(m.getName())) {
                assertNotNull(m.getAnnotation(Transactional.class),
                        "PaymentRecorder." + m.getName() + " must be @Transactional");
            }
        }
    }
}
