/*
 * Named fault points. `COSMIC_FAULT("curl_easy_init")` is true when a
 * test has armed that point with `testing.fail_at` and its turn has
 * come, and the call it guards then reports a failure of its own shape
 * instead of being made -- which is how a test reaches a library call's
 * failure paths when nothing it can arrange makes the library fail.
 *
 * Only the checked core has fault points (core/testing_checked.c); in
 * every other core the macro is the constant 0, and the guarded call is
 * all that is compiled.
 */

#ifndef COSMIC_FAULT_H
#define COSMIC_FAULT_H

#ifdef COSMIC_CHECKED

/* True, once, when `point` is armed and its skipped calls are used up. */
int cosmic_fault (const char *point);
#define COSMIC_FAULT(point) cosmic_fault(point)

#else

#define COSMIC_FAULT(point) 0

#endif

#endif
