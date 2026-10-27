#include "record_control.h"

#include <assert.h>
#include <stdlib.h>
#include <string.h>

#include "events.h"
#include "shortcut_mod.h"
#include "util/log.h"
#include "util/str.h"

#define SC_RECORD_CONTROL_POLL_MS 500
#define SC_RECORD_CONTROL_MAX_QUEUED_POLLS 10
#define SC_RECORD_CONTROL_PENDING_TIMEOUT SC_TICK_FROM_SEC(10)

#define SC_RECORD_BUTTON_SIZE 36.f
#define SC_RECORD_BUTTON_MARGIN 10.f
#define SC_RECORD_BUTTON_SEGMENTS 32

static uint32_t SDLCALL
poll_timer_cb(void *userdata, SDL_TimerID id, uint32_t interval) {
    (void) id;
    struct sc_record_control *rc = userdata;

    int queued = SDL_AddAtomicInt(&rc->queued_polls, 1);
    if (queued == 0 || queued >= SC_RECORD_CONTROL_MAX_QUEUED_POLLS) {
        if (queued) {
            SDL_SetAtomicInt(&rc->queued_polls, 1);
        }
        sc_push_event(SC_EVENT_RECORD_CONTROL_POLL);
    }

    return interval;
}

static bool
read_state(struct sc_record_control *rc) {
    size_t size;
    char *data = SDL_LoadFile(rc->path, &size);
    if (!data) {
        return false;
    }

    bool recording = size > 0 && data[0] == '1';
    SDL_free(data);
    return recording;
}

static bool
write_request(struct sc_record_control *rc, bool start) {
    const char *content = start ? "start\n" : "stop\n";

    SDL_IOStream *io = SDL_IOFromFile(rc->request_tmp_path, "wb");
    if (!io) {
        LOGE("Could not write %s: %s", rc->request_tmp_path, SDL_GetError());
        return false;
    }
    size_t len = strlen(content);
    bool ok = SDL_WriteIO(io, content, len) == len;
    ok &= SDL_CloseIO(io);
    if (!ok) {
        LOGE("Could not write %s: %s", rc->request_tmp_path, SDL_GetError());
        SDL_RemovePath(rc->request_tmp_path);
        return false;
    }

    if (!SDL_RenamePath(rc->request_tmp_path, rc->request_path)) {
        SDL_RemovePath(rc->request_path);
        if (!SDL_RenamePath(rc->request_tmp_path, rc->request_path)) {
            LOGE("Could not write %s: %s", rc->request_path, SDL_GetError());
            SDL_RemovePath(rc->request_tmp_path);
            return false;
        }
    }

    return true;
}

static void
toggle(struct sc_record_control *rc) {
    bool start = !rc->recording;
    if (!write_request(rc, start)) {
        return;
    }

    LOGI("Recording %s requested", start ? "start" : "stop");
    rc->recording = start;
    rc->pending = true;
    rc->pending_deadline = sc_tick_now() + SC_RECORD_CONTROL_PENDING_TIMEOUT;
}

static bool
poll(struct sc_record_control *rc) {
    SDL_SetAtomicInt(&rc->queued_polls, 0);

    bool recording = read_state(rc);
    bool old_recording = rc->recording;
    bool old_pending = rc->pending;

    if (!rc->pending || recording == rc->recording
            || sc_tick_now() >= rc->pending_deadline) {
        rc->pending = false;
        rc->recording = recording;
    }

    return rc->recording != old_recording || rc->pending != old_pending;
}

static bool
get_button_rect(SDL_Window *window, SDL_FRect *rect) {
    int w;
    int h;
    if (!SDL_GetWindowSize(window, &w, &h)) {
        return false;
    }

    float size = SC_RECORD_BUTTON_SIZE;
    float margin = SC_RECORD_BUTTON_MARGIN;
    if (w < size + 2 * margin || h < size + 2 * margin) {
        return false;
    }

    rect->x = w - margin - size;
    rect->y = margin;
    rect->w = size;
    rect->h = size;
    return true;
}

static bool
is_in_button(SDL_Window *window, float x, float y) {
    SDL_FRect rect;
    if (!get_button_rect(window, &rect)) {
        return false;
    }
    return x >= rect.x && x < rect.x + rect.w
        && y >= rect.y && y < rect.y + rect.h;
}

static bool
handle_mouse_button(struct sc_record_control *rc, SDL_Window *window,
                    const SDL_MouseButtonEvent *event, bool *render) {
    if (event->windowID != SDL_GetWindowID(window)
            || event->button != SDL_BUTTON_LEFT
            || event->which == SDL_TOUCH_MOUSEID) {
        return false;
    }

    if (event->down) {
        if (!is_in_button(window, event->x, event->y)) {
            return false;
        }
        rc->button_pressed = true;
        toggle(rc);
        *render = true;
        return true;
    }

    bool consumed = rc->button_pressed;
    rc->button_pressed = false;
    return consumed;
}

static bool
handle_finger(struct sc_record_control *rc, SDL_Window *window,
              const SDL_TouchFingerEvent *event, bool *render) {
    if (event->windowID != SDL_GetWindowID(window)) {
        return false;
    }

    if (event->type == SDL_EVENT_FINGER_DOWN) {
        int w;
        int h;
        if (!SDL_GetWindowSize(window, &w, &h)
                || !is_in_button(window, event->x * w, event->y * h)) {
            return false;
        }
        rc->finger_pressed = true;
        rc->finger_id = event->fingerID;
        toggle(rc);
        *render = true;
        return true;
    }

    if (!rc->finger_pressed || rc->finger_id != event->fingerID) {
        return false;
    }
    if (event->type != SDL_EVENT_FINGER_MOTION) {
        rc->finger_pressed = false;
    }
    return true;
}

static bool
handle_key(struct sc_record_control *rc, const SDL_KeyboardEvent *event,
           bool *render) {
    if (event->key != SDLK_E) {
        return false;
    }

    if (!event->down) {
        bool consumed = rc->key_pressed;
        rc->key_pressed = false;
        return consumed;
    }

    uint16_t mod = sc_sdl_mod_normalize(event->mod);
    if (!sc_shortcut_mods_is_shortcut_mod(rc->sdl_shortcut_mods, mod)
            || (mod & SDL_KMOD_SHIFT)) {
        return false;
    }

    rc->key_pressed = true;
    if (!event->repeat) {
        toggle(rc);
        *render = true;
    }
    return true;
}

bool
sc_record_control_handle_event(struct sc_record_control *rc,
                               SDL_Window *window, const SDL_Event *event,
                               bool handle_mouse, bool *render) {
    *render = false;

    switch (event->type) {
        case SC_EVENT_RECORD_CONTROL_POLL:
            *render = poll(rc);
            return true;
        case SDL_EVENT_MOUSE_BUTTON_DOWN:
        case SDL_EVENT_MOUSE_BUTTON_UP:
            if (!window || (!handle_mouse && !rc->button_pressed)) {
                return false;
            }
            return handle_mouse_button(rc, window, &event->button, render);
        case SDL_EVENT_FINGER_DOWN:
        case SDL_EVENT_FINGER_MOTION:
        case SDL_EVENT_FINGER_UP:
        case SDL_EVENT_FINGER_CANCELED:
            if (!window || (!handle_mouse && !rc->finger_pressed)) {
                return false;
            }
            return handle_finger(rc, window, &event->tfinger, render);
        case SDL_EVENT_KEY_DOWN:
        case SDL_EVENT_KEY_UP:
            return handle_key(rc, &event->key, render);
        default:
            return false;
    }
}

static void
fill_circle(SDL_Renderer *renderer, float cx, float cy, float radius,
            SDL_FColor color) {
    SDL_Vertex vertices[SC_RECORD_BUTTON_SEGMENTS + 1];
    int indices[SC_RECORD_BUTTON_SEGMENTS * 3];

    vertices[0].position.x = cx;
    vertices[0].position.y = cy;
    vertices[0].color = color;
    vertices[0].tex_coord.x = 0;
    vertices[0].tex_coord.y = 0;

    for (int i = 0; i < SC_RECORD_BUTTON_SEGMENTS; ++i) {
        float angle = 2 * SDL_PI_F * i / SC_RECORD_BUTTON_SEGMENTS;
        SDL_Vertex *v = &vertices[i + 1];
        v->position.x = cx + radius * SDL_cosf(angle);
        v->position.y = cy + radius * SDL_sinf(angle);
        v->color = color;
        v->tex_coord.x = 0;
        v->tex_coord.y = 0;

        indices[i * 3] = 0;
        indices[i * 3 + 1] = i + 1;
        indices[i * 3 + 2] = (i + 1) % SC_RECORD_BUTTON_SEGMENTS + 1;
    }

    SDL_RenderGeometry(renderer, NULL, vertices, SC_RECORD_BUTTON_SEGMENTS + 1,
                       indices, SC_RECORD_BUTTON_SEGMENTS * 3);
}

void
sc_record_control_render(struct sc_record_control *rc, SDL_Window *window,
                         SDL_Renderer *renderer) {
    SDL_FRect rect;
    if (!get_button_rect(window, &rect)) {
        return;
    }

    float scale = SDL_GetWindowPixelDensity(window);
    if (scale <= 0) {
        scale = 1;
    }

    float size = rect.w * scale;
    float cx = rect.x * scale + size / 2;
    float cy = rect.y * scale + size / 2;
    float alpha = rc->pending ? 0.5f : 1.f;

    SDL_BlendMode old_blend_mode;
    bool restore_blend_mode =
        SDL_GetRenderDrawBlendMode(renderer, &old_blend_mode);
    SDL_SetRenderDrawBlendMode(renderer, SDL_BLENDMODE_BLEND);

    if (rc->recording) {
        SDL_FColor red = {0.85f, 0.1f, 0.1f, 0.9f * alpha};
        fill_circle(renderer, cx, cy, size / 2, red);

        float side = size * 0.34f;
        SDL_FRect square = {cx - side / 2, cy - side / 2, side, side};
        SDL_SetRenderDrawColorFloat(renderer, 1.f, 1.f, 1.f, alpha);
        SDL_RenderFillRect(renderer, &square);
    } else {
        SDL_FColor background = {0.1f, 0.1f, 0.1f, 0.65f * alpha};
        fill_circle(renderer, cx, cy, size / 2, background);
        SDL_FColor red = {0.9f, 0.1f, 0.1f, alpha};
        fill_circle(renderer, cx, cy, size * 0.25f, red);
    }

    if (restore_blend_mode) {
        SDL_SetRenderDrawBlendMode(renderer, old_blend_mode);
    }
}

bool
sc_record_control_init(struct sc_record_control *rc, const char *path,
                       uint8_t shortcut_mods) {
    rc->path = strdup(path);
    rc->request_path = sc_str_concat(path, ".request");
    rc->request_tmp_path = sc_str_concat(path, ".request.tmp");
    if (!rc->path || !rc->request_path || !rc->request_tmp_path) {
        LOG_OOM();
        goto error;
    }

    rc->sdl_shortcut_mods = sc_shortcut_mods_to_sdl(shortcut_mods);
    SDL_SetAtomicInt(&rc->queued_polls, 0);
    rc->pending = false;
    rc->pending_deadline = 0;
    rc->button_pressed = false;
    rc->finger_pressed = false;
    rc->finger_id = 0;
    rc->key_pressed = false;
    rc->recording = read_state(rc);

    rc->timer = SDL_AddTimer(SC_RECORD_CONTROL_POLL_MS, poll_timer_cb, rc);
    if (!rc->timer) {
        LOGE("Could not create record control timer: %s", SDL_GetError());
        goto error;
    }

    return true;

error:
    free(rc->path);
    free(rc->request_path);
    free(rc->request_tmp_path);
    return false;
}

void
sc_record_control_destroy(struct sc_record_control *rc) {
    SDL_RemoveTimer(rc->timer);
    free(rc->path);
    free(rc->request_path);
    free(rc->request_tmp_path);
}
