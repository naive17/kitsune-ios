#ifndef IOSWINE_GAME_CONTROLLER_H
#define IOSWINE_GAME_CONTROLLER_H

#ifdef __cplusplus
extern "C" {
#endif

/* Idempotent; snapshots are safe to read from any native/Wine thread. */
void GameController_Start(void);

struct ios_touch_pad;
/* The on-screen pad's state; it joins slot 0. */
void GameController_SetTouchPad(const struct ios_touch_pad *state);

#ifdef __cplusplus
}
#endif

#endif
