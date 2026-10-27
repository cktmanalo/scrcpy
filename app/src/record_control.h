#ifndef SC_RECORD_CONTROL_H
#define SC_RECORD_CONTROL_H

#include "common.h"

#include <stdbool.h>
#include <stdint.h>
#include <SDL3/SDL.h>

#include "util/tick.h"

struct sc_record_control {
    char *path;
    char *request_path;
    char *request_tmp_path;
    uint16_t sdl_shortcut_mods;
    SDL_TimerID timer;
    SDL_AtomicInt queued_polls;

    bool recording;
    bool pending;
    sc_tick pending_deadline;

    bool button_pressed;
    bool finger_pressed;
    SDL_FingerID finger_id;
    bool key_pressed;
};

bool
sc_record_control_init(struct sc_record_control *rc, const char *path,
                       uint8_t shortcut_mods);

void
sc_record_control_destroy(struct sc_record_control *rc);

bool
sc_record_control_handle_event(struct sc_record_control *rc,
                               SDL_Window *window, const SDL_Event *event,
                               bool handle_mouse, bool *render);

void
sc_record_control_render(struct sc_record_control *rc, SDL_Window *window,
                         SDL_Renderer *renderer);

#endif
