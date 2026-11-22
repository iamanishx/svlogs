// json_parser: a streaming JSON parser.
//
// It reads one byte per clock and emits a stream of events, without ever
// storing the document. For the input
//
//     {"a": [1, true]}
//
// it emits
//
//     OBJ_START, KEY_START, STR_CHAR 'a', STR_END,
//     ARR_START, NUMBER 1, TRUE, ARR_END, OBJ_END
//
// Input side (valid/ready handshake):
//   A byte is taken on a rising clock edge where in_valid and in_ready are
//   both high. Raise in_last together with the final byte of the document.
//   in_ready drops for one cycle when a number is ended by the byte after it
//   (as in "12]"): that cycle emits NUMBER, the next one handles the "]".
//
// Output side:
//   ev_valid pulses with one event in ev_type / ev_data.
//   done pulses once per document, after its last byte. While done is high,
//   error says whether the document was invalid. The parser is then ready
//   for the next document; no reset is needed in between.
//
// Supported: objects, arrays, strings (escapes are checked but passed
// through undecoded), true, false, null, and integers that fit in int32.
// Not supported, reported as errors: fractions and exponents (1.5, 1e3),
// integers outside int32, and nesting deeper than MAX_DEPTH.

module json_parser #(
    parameter int MAX_DEPTH = 16
) (
    input  logic        clk,
    input  logic        rst,        // synchronous, active high

    input  logic        in_valid,
    output logic        in_ready,
    input  logic [7:0]  in_byte,
    input  logic        in_last,

    output logic        ev_valid,
    output logic [3:0]  ev_type,
    output logic [31:0] ev_data,    // STR_CHAR: the byte. NUMBER: signed value.

    output logic        done,
    output logic        error
);

    // Event codes on ev_type.
    localparam logic [3:0] EV_OBJ_START = 4'd0;
    localparam logic [3:0] EV_OBJ_END   = 4'd1;
    localparam logic [3:0] EV_ARR_START = 4'd2;
    localparam logic [3:0] EV_ARR_END   = 4'd3;
    localparam logic [3:0] EV_KEY_START = 4'd4;   // a string that is an object key
    localparam logic [3:0] EV_STR_START = 4'd5;   // a string that is a value
    localparam logic [3:0] EV_STR_CHAR  = 4'd6;
    localparam logic [3:0] EV_STR_END   = 4'd7;
    localparam logic [3:0] EV_NUMBER    = 4'd8;
    localparam logic [3:0] EV_TRUE      = 4'd9;
    localparam logic [3:0] EV_FALSE     = 4'd10;
    localparam logic [3:0] EV_NULL      = 4'd11;

    // What the parser is waiting for, or is in the middle of.
    typedef enum logic [3:0] {
        S_VALUE,         // a value must come next
        S_VALUE_OR_END,  // just after "[": a value, or "]"
        S_KEY_OR_END,    // just after "{": a key, or "}"
        S_KEY,           // after "," in an object: a key
        S_COLON,         // after a key: ":"
        S_AFTER,         // after a value inside a container: "," or the closer
        S_STRING,        // inside a string
        S_ESCAPE,        // just after a backslash
        S_HEX,           // inside the 4 hex digits of \uXXXX
        S_MINUS,         // just after "-": a digit must follow
        S_NUMBER,        // inside the digits of a number
        S_LITERAL,       // inside true / false / null
        S_DONE,          // top-level value finished: only whitespace allowed
        S_ERROR          // document is invalid: swallow bytes until in_last
    } state_t;

    localparam logic [1:0] LIT_TRUE  = 2'd0;
    localparam logic [1:0] LIT_FALSE = 2'd1;
    localparam logic [1:0] LIT_NULL  = 2'd2;

    localparam int DW = $clog2(MAX_DEPTH + 1);    // bits needed to count 0..MAX_DEPTH
    localparam int IW = $clog2(MAX_DEPTH);        // bits needed to index the stack

    // ---------------------------------------------------------------- state

    state_t        state,     state_n;
    logic [DW-1:0] depth,     depth_n;      // how many containers are open
    logic          stack [MAX_DEPTH];       // per level: 0 = object, 1 = array
    logic          is_key,    is_key_n;     // current string is an object key
    logic [1:0]    hex_cnt,   hex_cnt_n;    // hex digits seen so far in \uXXXX
    logic [1:0]    lit_kind,  lit_kind_n;   // which literal is being matched
    logic [2:0]    lit_idx,   lit_idx_n;    // position inside that literal
    logic          negative,  negative_n;   // number had a leading "-"
    logic          lead_zero, lead_zero_n;  // number started with "0"
    logic [31:0]   value,     value_n;      // magnitude of the number so far

    logic          ev_valid_n, done_n, error_n;
    logic [3:0]    ev_type_n;
    logic [31:0]   ev_data_n;

    // ------------------------------------------------- byte classification

    logic is_ws, is_digit, is_hex, top_is_arr;
    logic [7:0]    lit_expect;
    logic          lit_final;
    logic [3:0]    digit;                    // numeric value of an ASCII digit
    logic [35:0]   value_x10;                // wide enough to see an overflow
    logic [IW-1:0] top_idx, push_idx;        // stack slots to read and to write

    assign digit    = in_byte[3:0];          // "0".."9" are 8'h30..8'h39
    assign top_idx  = IW'(depth - 1'b1);
    assign push_idx = IW'(depth);

    // The number so far with the next digit appended: value * 10 + digit.
    assign value_x10 = {4'd0, value} * 36'd10 + {32'd0, digit};

    always_comb begin
        is_ws    = (in_byte == " ") || (in_byte == 8'h09) ||
                   (in_byte == 8'h0A) || (in_byte == 8'h0D);
        is_digit = (in_byte >= "0") && (in_byte <= "9");
        is_hex   = is_digit ||
                   ((in_byte >= "a") && (in_byte <= "f")) ||
                   ((in_byte >= "A") && (in_byte <= "F"));

        // The innermost open container. Only meaningful when depth > 0.
        top_is_arr = stack[top_idx];

        // The character the current literal expects at position lit_idx.
        lit_expect = 8'h00;
        case (lit_kind)
            LIT_TRUE:  case (lit_idx)
                           3'd1: lit_expect = "r";
                           3'd2: lit_expect = "u";
                           3'd3: lit_expect = "e";
                           default: ;
                       endcase
            LIT_FALSE: case (lit_idx)
                           3'd1: lit_expect = "a";
                           3'd2: lit_expect = "l";
                           3'd3: lit_expect = "s";
                           3'd4: lit_expect = "e";
                           default: ;
                       endcase
            LIT_NULL:  case (lit_idx)
                           3'd1: lit_expect = "u";
                           3'd2: lit_expect = "l";
                           3'd3: lit_expect = "l";
                           default: ;
                       endcase
            default: ;
        endcase
        lit_final = (lit_kind == LIT_FALSE) ? (lit_idx == 3'd4) : (lit_idx == 3'd3);
    end

    // ------------------------------------------------------ next-state logic

    // Requests raised by the state case below and carried out after it, so
    // that shared actions (start a value, close a container, ...) are
    // written only once.
    logic start_value;   // this byte begins a value
    logic start_key;     // this byte is the opening quote of a key
    logic first_digit;   // this byte is the first digit of a number
    logic close_obj;     // this byte is a "}" that closes the innermost object
    logic close_arr;     // this byte is a "]" that closes the innermost array
    logic number_done;   // the number is complete: emit it
    logic value_done;    // a whole value just finished
    logic fail;          // the document is invalid
    logic push, push_kind;

    always_comb begin
        state_n     = state;
        depth_n     = depth;
        is_key_n    = is_key;
        hex_cnt_n   = hex_cnt;
        lit_kind_n  = lit_kind;
        lit_idx_n   = lit_idx;
        negative_n  = negative;
        lead_zero_n = lead_zero;
        value_n     = value;

        ev_valid_n  = 1'b0;
        ev_type_n   = EV_OBJ_START;
        ev_data_n   = 32'd0;
        done_n      = 1'b0;
        error_n     = 1'b0;

        in_ready    = 1'b1;
        start_value = 1'b0;
        start_key   = 1'b0;
        first_digit = 1'b0;
        close_obj   = 1'b0;
        close_arr   = 1'b0;
        number_done = 1'b0;
        value_done  = 1'b0;
        fail        = 1'b0;
        push        = 1'b0;
        push_kind   = 1'b0;

        if (in_valid) begin

            // ---- 1. Decide what this byte means in the current state.
            case (state)
                S_VALUE: begin
                    if (!is_ws) start_value = 1'b1;
                end

                S_VALUE_OR_END: begin
                    if (is_ws) ;
                    else if (in_byte == "]") close_arr = 1'b1;
                    else start_value = 1'b1;
                end

                S_KEY_OR_END: begin
                    if (is_ws) ;
                    else if (in_byte == "}") close_obj = 1'b1;
                    else if (in_byte == "\"") start_key = 1'b1;
                    else fail = 1'b1;
                end

                S_KEY: begin
                    if (is_ws) ;
                    else if (in_byte == "\"") start_key = 1'b1;
                    else fail = 1'b1;
                end

                S_COLON: begin
                    if (is_ws) ;
                    else if (in_byte == ":") state_n = S_VALUE;
                    else fail = 1'b1;
                end

                S_AFTER: begin
                    if (is_ws) ;
                    else if (in_byte == ",") begin
                        if (top_is_arr) state_n = S_VALUE;
                        else state_n = S_KEY;
                    end
                    else if (in_byte == "}" && !top_is_arr) close_obj = 1'b1;
                    else if (in_byte == "]" && top_is_arr) close_arr = 1'b1;
                    else fail = 1'b1;
                end

                S_STRING: begin
                    if (in_byte == "\"") begin
                        ev_valid_n = 1'b1;
                        ev_type_n  = EV_STR_END;
                        if (is_key) state_n = S_COLON;
                        else value_done = 1'b1;
                    end else if (in_byte < 8'h20) begin
                        fail = 1'b1;               // raw control characters are illegal
                    end else begin
                        ev_valid_n = 1'b1;
                        ev_type_n  = EV_STR_CHAR;
                        ev_data_n  = {24'd0, in_byte};
                        if (in_byte == "\\") state_n = S_ESCAPE;
                    end
                end

                S_ESCAPE: begin
                    ev_valid_n = 1'b1;
                    ev_type_n  = EV_STR_CHAR;
                    ev_data_n  = {24'd0, in_byte};
                    case (in_byte)
                        "\"", "\\", "/", "b", "f", "n", "r", "t": state_n = S_STRING;
                        "u": begin
                            hex_cnt_n = 2'd0;
                            state_n   = S_HEX;
                        end
                        default: fail = 1'b1;
                    endcase
                end

                S_HEX: begin
                    ev_valid_n = 1'b1;
                    ev_type_n  = EV_STR_CHAR;
                    ev_data_n  = {24'd0, in_byte};
                    if (!is_hex) fail = 1'b1;
                    else if (hex_cnt == 2'd3) state_n = S_STRING;
                    else hex_cnt_n = hex_cnt + 2'd1;
                end

                S_MINUS: begin
                    if (is_digit) first_digit = 1'b1;
                    else fail = 1'b1;
                end

                S_NUMBER: begin
                    if (is_digit) begin
                        // "01" is illegal, and the magnitude may not pass 2^31.
                        if (lead_zero || value_x10 > 36'h0_8000_0000) fail = 1'b1;
                        else begin
                            value_n = 32'(value_x10);
                            if (in_last) number_done = 1'b1;
                        end
                    end else if (in_byte == "." || in_byte == "e" || in_byte == "E") begin
                        fail = 1'b1;               // fractions and exponents: not supported
                    end else begin
                        // Any other byte ends the number. Emit the number now
                        // and leave the byte on the input for the next cycle.
                        number_done = 1'b1;
                        in_ready    = 1'b0;
                    end
                end

                S_LITERAL: begin
                    if (in_byte != lit_expect) fail = 1'b1;
                    else if (lit_final) begin
                        ev_valid_n = 1'b1;
                        case (lit_kind)
                            LIT_TRUE:  ev_type_n = EV_TRUE;
                            LIT_FALSE: ev_type_n = EV_FALSE;
                            default:   ev_type_n = EV_NULL;
                        endcase
                        value_done = 1'b1;
                    end else begin
                        lit_idx_n = lit_idx + 3'd1;
                    end
                end

                S_DONE: begin
                    if (!is_ws) fail = 1'b1;       // nothing may follow the value
                end

                default: ;                         // S_ERROR: swallow the byte
            endcase

            // ---- 2. Carry out the shared actions.

            if (start_key) begin
                ev_valid_n = 1'b1;
                ev_type_n  = EV_KEY_START;
                is_key_n   = 1'b1;
                state_n    = S_STRING;
            end

            if (start_value) begin
                case (in_byte)
                    "{", "[": begin
                        if (depth == DW'(MAX_DEPTH)) fail = 1'b1;   // nested too deep
                        else begin
                            push       = 1'b1;
                            push_kind  = (in_byte == "[");
                            depth_n    = depth + 1'b1;
                            ev_valid_n = 1'b1;
                            ev_type_n  = (in_byte == "[") ? EV_ARR_START : EV_OBJ_START;
                            if (in_byte == "[") state_n = S_VALUE_OR_END;
                            else state_n = S_KEY_OR_END;
                        end
                    end
                    "\"": begin
                        ev_valid_n = 1'b1;
                        ev_type_n  = EV_STR_START;
                        is_key_n   = 1'b0;
                        state_n    = S_STRING;
                    end
                    "-": begin
                        negative_n = 1'b1;
                        state_n    = S_MINUS;
                    end
                    "t": begin lit_kind_n = LIT_TRUE;  lit_idx_n = 3'd1; state_n = S_LITERAL; end
                    "f": begin lit_kind_n = LIT_FALSE; lit_idx_n = 3'd1; state_n = S_LITERAL; end
                    "n": begin lit_kind_n = LIT_NULL;  lit_idx_n = 3'd1; state_n = S_LITERAL; end
                    default: begin
                        if (is_digit) begin
                            negative_n  = 1'b0;
                            first_digit = 1'b1;
                        end else fail = 1'b1;
                    end
                endcase
            end

            if (first_digit) begin
                value_n     = {28'd0, digit};
                lead_zero_n = (in_byte == "0");
                state_n     = S_NUMBER;
                if (in_last) number_done = 1'b1;
            end

            if (close_obj || close_arr) begin
                depth_n    = depth - 1'b1;
                ev_valid_n = 1'b1;
                ev_type_n  = close_arr ? EV_ARR_END : EV_OBJ_END;
                value_done = 1'b1;
            end

            if (number_done) begin
                // +2^31 does not fit in int32 (only -2^31 does).
                if (!negative_n && value_n == 32'h8000_0000) fail = 1'b1;
                ev_valid_n = 1'b1;
                ev_type_n  = EV_NUMBER;
                ev_data_n  = negative_n ? (~value_n + 32'd1) : value_n;
                value_done = 1'b1;
            end

            // ---- 3. A finished value: back to the enclosing container.
            if (value_done) begin
                if (depth_n == '0) state_n = S_DONE;
                else state_n = S_AFTER;
            end

            // ---- 4. An error overrides everything this byte tried to do.
            if (fail) begin
                state_n    = S_ERROR;
                depth_n    = depth;
                push       = 1'b0;
                ev_valid_n = 1'b0;
            end

            // ---- 5. End of the document: report, and start afresh.
            if (in_ready && in_last) begin
                done_n  = 1'b1;
                error_n = (state_n != S_DONE);
                state_n = S_VALUE;
                depth_n = '0;
            end
        end
    end

    // ------------------------------------------------------------ registers

    always_ff @(posedge clk) begin
        if (rst) begin
            state     <= S_VALUE;
            depth     <= '0;
            is_key    <= 1'b0;
            hex_cnt   <= 2'd0;
            lit_kind  <= LIT_TRUE;
            lit_idx   <= 3'd0;
            negative  <= 1'b0;
            lead_zero <= 1'b0;
            value     <= 32'd0;
            ev_valid  <= 1'b0;
            ev_type   <= EV_OBJ_START;
            ev_data   <= 32'd0;
            done      <= 1'b0;
            error     <= 1'b0;
        end else begin
            state     <= state_n;
            depth     <= depth_n;
            is_key    <= is_key_n;
            hex_cnt   <= hex_cnt_n;
            lit_kind  <= lit_kind_n;
            lit_idx   <= lit_idx_n;
            negative  <= negative_n;
            lead_zero <= lead_zero_n;
            value     <= value_n;
            ev_valid  <= ev_valid_n;
            ev_type   <= ev_type_n;
            ev_data   <= ev_data_n;
            done      <= done_n;
            error     <= error_n;
        end
    end

    // The stack is a small memory with no reset: an entry is always written
    // by a push before anything reads it.
    always_ff @(posedge clk) begin
        if (push) stack[push_idx] <= push_kind;
    end

endmodule
