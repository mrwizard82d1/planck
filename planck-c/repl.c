#include <ctype.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <unistd.h>
#include<sys/socket.h>
#include<arpa/inet.h>

#include "linenoise.h"

#include "cljs.h"
#include "globals.h"
#include "str.h"
#include "theme.h"
#include "timers.h"

pthread_mutex_t eval_lock = PTHREAD_MUTEX_INITIALIZER;

JSContextRef global_ctx;

struct repl_state {
    char *current_ns;
    char *current_prompt;
    char *history_path;
    char *input;
    int indent_space_count;
    size_t num_previous_lines;
    char **previous_lines;
    long socket_repl_session_id;
};

typedef struct repl_state repl_state_t;

repl_state_t* make_repl_state() {
    repl_state_t* repl_state = malloc(sizeof(repl_state_t));
    repl_state->current_ns = strdup("cljs.user");
    repl_state->current_prompt = NULL;
    repl_state->history_path = NULL;
    repl_state->input = NULL;
    repl_state->indent_space_count = 0;
    repl_state->num_previous_lines = 0;
    repl_state->previous_lines = NULL;
    repl_state->socket_repl_session_id = 0;
    return repl_state;
}

void empty_previous_lines(repl_state_t* repl_state) {
    for (int i = 0; i < repl_state->num_previous_lines; i++) {
        free(repl_state->previous_lines[i]);
    }
    free(repl_state->previous_lines);
    repl_state->num_previous_lines = 0;
    repl_state->previous_lines = NULL;
}

char *form_prompt(char *current_ns, bool is_secondary) {
    char *prompt = NULL;
    if (!is_secondary) {
        if (strlen(current_ns) == 1 && !config.dumb_terminal) {
            prompt = malloc(6 * sizeof(char));
            sprintf(prompt, " %s=> ", current_ns);
        } else {
            prompt = str_concat(current_ns, "=> ");
        }
    } else {
        if (!config.dumb_terminal) {
            size_t len = strlen(current_ns) - 2;
            prompt = malloc((len + 6) * sizeof(char));
            memset(prompt, ' ', len);
            sprintf(prompt + len, "#_=> ");
        }
    }

    return prompt;
}

char *get_input() {
    char *line = NULL;
    size_t len = 0;
    ssize_t n = getline(&line, &len, stdin);
    if (n > 0) {
        if (line[n - 1] == '\n') {
            line[n - 1] = '\0';
        }
    }
    return line;
}

void display_prompt(char *prompt) {
    if (prompt != NULL) {
        fprintf(stdout, "%s", prompt);
        fflush(stdout);
    }
}

bool is_whitespace(char *s) {
    size_t len = strlen(s);
    for (int i = 0; i < len; i++) {
        if (!isspace(s[i])) {
            return false;
        }
    }

    return true;
}

bool process_line(repl_state_t* repl_state, JSContextRef ctx, char *input_line) {
    // Accumulate input lines

    if (repl_state->input == NULL) {
        repl_state->input = input_line;
    } else {
        repl_state->input = realloc(repl_state->input, (strlen(repl_state->input) + strlen(input_line) + 2) * sizeof(char));
        sprintf(repl_state->input + strlen(repl_state->input), "\n%s", input_line);
    }

    repl_state->num_previous_lines += 1;
    repl_state->previous_lines = realloc(repl_state->previous_lines, repl_state->num_previous_lines * sizeof(char *));
    repl_state->previous_lines[repl_state->num_previous_lines - 1] = strdup(input_line);

    // Check for explicit exit

    if (strcmp(repl_state->input, ":cljs/quit") == 0 ||
        strcmp(repl_state->input, "quit") == 0 ||
        strcmp(repl_state->input, "exit") == 0) {
        if (repl_state->socket_repl_session_id == 0) {
            exit_value = EXIT_SUCCESS_INTERNAL;
        }
        return true;
    }

    // Add input line to history

    if (repl_state->history_path != NULL && !is_whitespace(repl_state->input)) {
        linenoiseHistoryAdd(input_line);
        linenoiseHistorySave(repl_state->history_path);
    }

    // Check if we now have readable forms
    // and if so, evaluate them

    bool done = false;
    char *balance_text = NULL;

    while (!done) {
        if ((balance_text = cljs_is_readable(ctx, repl_state->input)) != NULL) {
            repl_state->input[strlen(repl_state->input) - strlen(balance_text)] = '\0';

            if (!is_whitespace(repl_state->input)) { // Guard against empty string being read
                pthread_mutex_lock(&eval_lock);

                return_termsize = !config.dumb_terminal;

                set_int_handler();

                // TODO: set exit value
                evaluate_source(ctx, "text", repl_state->input, true, true, repl_state->current_ns, config.theme, true);

                clear_int_handler();

                return_termsize = false;

                pthread_mutex_unlock(&eval_lock);

                if (exit_value != 0) {
                    free(repl_state->input);
                    return true;
                }
            } else {
                printf("\n");
            }

            // Now that we've evaluated the input, reset for next round
            free(repl_state->input);
            repl_state->input = balance_text;

            empty_previous_lines(repl_state);

            // Fetch the current namespace and use it to set the prompt
            free(repl_state->current_ns);
            free(repl_state->current_prompt);

            repl_state->current_ns = get_current_ns(ctx);
            repl_state->current_prompt = form_prompt(repl_state->current_ns, false);

            if (is_whitespace(balance_text)) {
                done = true;
                free(repl_state->input);
                repl_state->input = NULL;
            }
        } else {
            // Prepare for reading non-1st of input with secondary prompt
            if (repl_state->history_path != NULL) {
                repl_state->indent_space_count = cljs_indent_space_count(ctx, repl_state->input);
            }

            free(repl_state->current_prompt);
            repl_state->current_prompt = form_prompt(repl_state->current_ns, true);
            done = true;
        }
    }

    return false;
}

void run_cmdline_loop(repl_state_t* repl_state, JSContextRef ctx) {
    while (true) {
        char *input_line = NULL;

        if (config.dumb_terminal) {
            display_prompt(repl_state->current_prompt);
            input_line = get_input();
            if (input_line == NULL) { // Ctrl-D pressed
                printf("\n");
                break;
            }
        } else {
            // Handle prints while processing linenoise input
            if (cljs_engine_ready) {
                cljs_set_print_sender(ctx, &linenoisePrintNow);
            }

            // If *print-newline* is off, we need to emit a newline now, otherwise
            // the linenoise prompt and line editing will overwrite any printed
            // output on the current line.
            if (cljs_engine_ready && !cljs_print_newline(ctx)) {
                fprintf(stdout, "\n");
            }

            char *line = linenoise(repl_state->current_prompt, prompt_ansi_code_for_theme(config.theme), repl_state->indent_space_count);

            // Reset printing handler back
            if (cljs_engine_ready) {
                cljs_set_print_sender(ctx, NULL);
            }

            repl_state->indent_space_count = 0;
            if (line == NULL) {
                if (errno == EAGAIN) { // Ctrl-C
                    errno = 0;
                    repl_state->input = NULL;
                    empty_previous_lines(repl_state);
                    repl_state->current_prompt = form_prompt(repl_state->current_ns, false);
                    printf("\n");
                    continue;
                } else { // Ctrl-D
                    exit_value = EXIT_SUCCESS_INTERNAL;
                    break;
                }
            }

            input_line = line;
        }

        bool break_out = process_line(repl_state, ctx, input_line);
        if (break_out) {
            break;
        }
    }
}

void completion(const char *buf, linenoiseCompletions *lc) {
    int num_completions = 0;
    char **completions = get_completions(global_ctx, buf, &num_completions);
    for (int i = 0; i < num_completions; i++) {
        linenoiseAddCompletion(lc, completions[i]);
        free(completions[i]);
    }
    free(completions);
}

pthread_mutex_t highlight_restore_sequence_mutex = PTHREAD_MUTEX_INITIALIZER;
int highlight_restore_sequence = 0;

struct hl_restore {
    int id;
    int num_lines_up;
    int relative_horiz;
};

struct hl_restore hl_restore = {0, 0, 0};

void do_highlight_restore(void* data) {

    struct hl_restore *hl_restore = data;

    int highlight_restore_sequence_value;
    pthread_mutex_lock(&highlight_restore_sequence_mutex);
    highlight_restore_sequence_value = highlight_restore_sequence;
    pthread_mutex_unlock(&highlight_restore_sequence_mutex);

    if (hl_restore->id == highlight_restore_sequence_value) {

        pthread_mutex_lock(&highlight_restore_sequence_mutex);
        ++highlight_restore_sequence;
        pthread_mutex_unlock(&highlight_restore_sequence_mutex);

        if (hl_restore->num_lines_up != 0) {
            fprintf(stdout, "\x1b[%dB", hl_restore->num_lines_up);
        }

        if (hl_restore->relative_horiz < 0) {
            fprintf(stdout, "\x1b[%dC", -hl_restore->relative_horiz);
        } else if (hl_restore->relative_horiz > 0) {
            fprintf(stdout, "\x0b[%dD", hl_restore->relative_horiz);
        }

        fflush(stdout);

    }

    free(hl_restore);
}

// Used when using linenoise
repl_state_t* s_repl_state;

void highlight(const char *buf, int pos) {
    char current = buf[pos];

    if (current == ']' || current == '}' || current == ')') {
        int num_lines_up = -1;
        int highlight_pos = 0;
        cljs_highlight_coords_for_pos(global_ctx, pos, buf, s_repl_state->num_previous_lines, s_repl_state->previous_lines, &num_lines_up,
                                      &highlight_pos);

        int current_pos = pos + 1;

        if (num_lines_up != -1) {
            int relative_horiz = highlight_pos - current_pos;

            if (num_lines_up != 0) {
                fprintf(stdout, "\x1b[%dA", num_lines_up);
            }

            if (relative_horiz < 0) {
                fprintf(stdout, "\x1b[%dD", -relative_horiz);
            } else if (relative_horiz > 0) {
                fprintf(stdout, "\x1b[%dC", relative_horiz);
            }

            fflush(stdout);

            struct hl_restore *hl_restore_local = malloc(sizeof(struct hl_restore));
            pthread_mutex_lock(&highlight_restore_sequence_mutex);
            hl_restore_local->id = ++highlight_restore_sequence;
            pthread_mutex_unlock(&highlight_restore_sequence_mutex);
            hl_restore_local->num_lines_up = num_lines_up;
            hl_restore_local->relative_horiz = relative_horiz;

            hl_restore = *hl_restore_local;

            start_timer(500, do_highlight_restore, (void *) hl_restore_local);
        }
    }
}

void highlight_cancel() {
    if (hl_restore.id != 0) {
        struct hl_restore *hl_restore_tmp = malloc(sizeof(struct hl_restore));
        *hl_restore_tmp = hl_restore;
        do_highlight_restore(hl_restore_tmp);
    }
}

int sock_to_write_to = 0;

void socket_sender(const char *text) {
    if (sock_to_write_to) {
        write(sock_to_write_to, text, strlen(text));
    }
}

void *connection_handler(void *socket_desc) {
    repl_state_t* repl_state = make_repl_state();
    repl_state->current_prompt = form_prompt(repl_state->current_ns, false);

    repl_state->socket_repl_session_id = (long)repl_state;

    int sock = *(int *) socket_desc;
    ssize_t read_size;
    char client_message[2000];

    write(sock, repl_state->current_prompt, strlen(repl_state->current_prompt));

    while ((read_size = recv(sock, client_message, 2000, 0)) > 0) {
        sock_to_write_to = sock;
        cljs_set_print_sender(global_ctx, &socket_sender);

        process_line(repl_state, global_ctx, strdup(client_message));

        cljs_set_print_sender(global_ctx, nil);
        sock_to_write_to = 0;

        write(sock, repl_state->current_prompt, strlen(repl_state->current_prompt));
    }

    free(socket_desc);

    return NULL;
}

void *accept_connections(void *data) {

    int socket_desc, new_socket, c, *new_sock;
    struct sockaddr_in server, client;

    socket_desc = socket(AF_INET, SOCK_STREAM, 0);
    if (socket_desc == -1) {
        perror("Could not create listen socket");
        return NULL;
    }

    server.sin_family = AF_INET;
    server.sin_addr.s_addr = INADDR_ANY;
    server.sin_port = htons(8888);

    if (bind(socket_desc, (struct sockaddr *) &server, sizeof(server)) < 0) {
        perror("Socket bind failed");
        return NULL;
    }

    listen(socket_desc, 3);

    // TODO: format address:port
    fprintf(stdout, "Planck socket REPL listening at localhost:8888.\n");

    c = sizeof(struct sockaddr_in);
    while ((new_socket = accept(socket_desc, (struct sockaddr *) &client, (socklen_t *) &c))) {

        pthread_t handler_thread;
        new_sock = malloc(1);
        *new_sock = new_socket;

        if (pthread_create(&handler_thread, NULL, connection_handler, (void *) new_sock) < 0) {
            perror("could not create thread");
            return NULL;
        }
    }

    if (new_socket < 0) {
        perror("accept failed");
        return NULL;
    }

    return NULL;
}

int run_repl(JSContextRef ctx) {
    repl_state_t* repl_state = make_repl_state();
    s_repl_state = repl_state;

    global_ctx = ctx;

    repl_state->current_ns = strdup("cljs.user");
    repl_state->current_prompt = form_prompt(repl_state->current_ns, false);

    // Per-type initialization

    if (!config.dumb_terminal) {
        char *home = getenv("HOME");
        if (home != NULL) {
            char history_name[] = ".planck_history";
            size_t len = strlen(home) + strlen(history_name) + 2;
            repl_state->history_path = malloc(len * sizeof(char));
            snprintf(repl_state->history_path, len, "%s/%s", home, history_name);

            linenoiseHistoryLoad(repl_state->history_path);

            // TODO: load keymap
        }

        linenoiseSetMultiLine(1);
        linenoiseSetCompletionCallback(completion);
        linenoiseSetHighlightCallback(highlight);
        linenoiseSetHighlightCancelCallback(highlight_cancel);
    }

    // TODO: pass address and port
    // TODO: only conditionally start accepting socket connections
    pthread_t thread;
    pthread_create(&thread, NULL, accept_connections, (void *) NULL);

    run_cmdline_loop(repl_state, ctx);

    return exit_value;
}
