cdef void _skip_single_line(ReaderRef reader) nogil:
    cdef uint32_t c0
    while _reader_good(reader):
        c0 = _reader_get(reader)
        if _is_line_terminator(c0):
            break


cdef boolean _skip_multiline_comment(ReaderRef reader) except False:
    cdef uint32_t c0
    cdef boolean seen_asterisk = False
    cdef Py_ssize_t comment_start = _reader_tell(reader)

    comment_start = _reader_tell(reader)

    seen_asterisk = False
    while _reader_good(reader):
        c0 = _reader_get(reader)
        if c0 == b'*':
            seen_asterisk = True
        elif seen_asterisk:
            if c0 == b'/':
                return True
            seen_asterisk = False

    return _raise_unclosed('comment', comment_start)


#    data found
# -1 exhausted
# -2 exception
cdef int32_t _skip_to_data_sub(ReaderRef reader, uint32_t c0) except -2:
    cdef int32_t c1
    cdef boolean seen_slash

    seen_slash = False
    while True:
        if c0 == b'/':
            if seen_slash:
                _skip_single_line(reader)
                seen_slash = False
            else:
                seen_slash = True
        elif c0 == b'*':
            if not seen_slash:
                _raise_stray_character('asterisk', _reader_tell(reader))

            _skip_multiline_comment(reader)
            seen_slash = False
        elif _is_ws_zs(c0):
            if seen_slash:
                _raise_stray_character('slash', _reader_tell(reader))
        else:
            c1 = cast_to_int32(c0)
            break

        if _reader_good(reader):
            c0 = _reader_get(reader)
        else:
            c1 = -1
            break

    if seen_slash:
        _raise_stray_character('slash', _reader_tell(reader))

    return c1


#    data found
# -1 exhausted
# -2 exception
cdef int32_t _skip_to_data(ReaderRef reader) except -2:
    cdef uint32_t c0
    cdef int32_t c1
    if _reader_good(reader):
        c0 = _reader_get(reader)
        c1 = _skip_to_data_sub(reader, c0)
    else:
        c1 = -1
    return c1


cdef int32_t _get_hex_character(ReaderRef reader, Py_ssize_t length) except -1:
    cdef Py_ssize_t start
    cdef uint32_t c0
    cdef uint32_t result
    cdef Py_ssize_t index

    start = _reader_tell(reader)
    result = 0
    for index in range(length):
        result <<= 4
        if not _reader_good(reader):
            _raise_unclosed('escape sequence', start)

        c0 = _reader_get(reader)
        if b'0' <= c0 <= b'9':
            result |= c0 - <uint32_t> b'0'
        elif b'a' <= c0 <= b'f':
            result |= c0 - <uint32_t> b'a' + 10
        elif b'A' <= c0 <= b'F':
            result |= c0 - <uint32_t> b'A' + 10
        else:
            _raise_expected_s('hexadecimal character', start, c0)

    if not (0 <= result <= 0x10ffff):
        _raise_expected_s('Unicode code point', start, result)

    return cast_to_int32(result)


# >=  0: character to append
#    -1: skip
# <  -1: -(next character + 1)
cdef int32_t _get_escape_sequence(ReaderRef reader, Py_ssize_t start) except 0x7ffffff:
    cdef uint32_t c0
    cdef uint32_t c1

    c0 = _reader_get(reader)
    if not _reader_good(reader):
        _raise_unclosed('string', start)

    if c0 == b'b':
        return 0x0008
    elif c0 == b'f':
        return 0x000c
    elif c0 == b'n':
        return 0x000a
    elif c0 == b'r':
        return 0x000d
    elif c0 == b't':
        return 0x0009
    elif c0 == b'v':
        return 0x000b
    elif c0 == b'0':
        return 0x0000
    elif c0 == b'x':
        return _get_hex_character(reader, 2)
    elif c0 == b'u':
        c0 = cast_to_uint32(_get_hex_character(reader, 4))
        if not Py_UNICODE_IS_HIGH_SURROGATE(c0):
            return c0

        _accept_string(reader, b'\\u')

        c1 = cast_to_uint32(_get_hex_character(reader, 4))
        if not Py_UNICODE_IS_LOW_SURROGATE(c1):
            _raise_expected_s('low surrogate', start, c1)

        return Py_UNICODE_JOIN_SURROGATES(c0, c1)
    elif c0 == b'U':
        return _get_hex_character(reader, 8)
    elif b'1' <= c0 <= b'9':
        _raise_expected_s('escape sequence', start, c0)
        return -2
    elif _is_line_terminator(c0):
        if c0 != 0x000D:
            return -1

        c0 = _reader_get(reader)
        if c0 == 0x000A:
            return -1

        return -cast_to_int32(c0 + 1)
    else:
        return cast_to_int32(c0)


cdef object _decode_string(ReaderRef reader, uint32_t delim):
    cdef uint32_t c0
    cdef int32_t c1
    cdef Py_ssize_t start

    cdef PyObject *buf = NULL
    cdef Py_ssize_t pos = 0
    cdef Py_ssize_t length = 0

    start = _reader_tell(reader)
    try:
        if not _reader_good(reader):
            _raise_unclosed('string', start)

        c0 = _reader_get(reader)
        while True:
            if c0 == delim:
                break

            if not _reader_good(reader):
                _raise_unclosed('string', start)

            if c0 != b'\\':
                _unicode_append(&buf, &pos, &length, c0)
                c0 = _reader_get(reader)
                continue

            c1 = _get_escape_sequence(reader, start)
            if c1 >= -1:
                if not _reader_good(reader):
                    _raise_unclosed('string', start)
                c0 = _reader_get(reader)

                if c1 >= 0:
                    _unicode_append(&buf, &pos, &length, cast_to_uint32(c1))
            else:
                c0 = cast_to_uint32(-(c1 + 1))

        if pos == 0:
            return ''
        elif pos < length:
            UnicodeResize(&buf, pos)

        return <object> buf
    finally:
        XDecRef(buf)


cdef object _decode_number(ReaderRef reader, uint32_t c0):
    cdef uint32_t c0
    cdef int32_t c1
    cdef Py_ssize_t start

    # TODO: bytes
    #cdef PyObject *buf = NULL
    #cdef Py_ssize_t pos = 0
    #cdef Py_ssize_t length = 0

    cdef boolean is_float = False
    cdef boolean is_negative = False

    if c0 == b'+':
        if not _reader_good(reader):
            _raise_unclosed('number', start)

        c0 = _reader_get(reader)
        if c == 'I':
            _accept_string(reader, b'nfinity')
            return CONST_POS_INF
        elif c == 'N':
            _accept_string(reader, b'aN')
            return CONST_POS_NAN
    elif c0 == b'-':
        if not _reader_good(reader):
            _raise_unclosed('number', start)

        c0 = _reader_get(reader)
        if c == 'I':
            _accept_string(reader, b'nfinity')
            return CONST_NEG_INF
        elif c == 'N':
            _accept_string(reader, b'aN')
            return CONST_NEG_NAN

        is_negative = True

    try:
    finally:
        XDecRef(buf)


#    data found
# -1 done
# -2 exception
cdef int32_t _skip_comma(
    ReaderRef reader,
    Py_ssize_t start,
    boolean *needs_comma,
    uint32_t terminator,
    str what,
) except -2:
    cdef int32_t c0
    cdef uint32_t c1
    while True:
        c0 = _skip_to_data(reader)
        if c0 < 0:
            _raise_unclosed(what, start)
        c1 = cast_to_uint32(c0)

        if c1 == terminator:
            c0 = -1
            break
        elif c1 == b',':
            if not needs_comma[0]:
                _raise_stray_character('comma', _reader_tell(reader))
            needs_comma[0] = False
            continue
        elif needs_comma[0]:
            _raise_expected_sc('comma', terminator, _reader_tell(reader), c1)

        c0 = _skip_to_data_sub(reader, c1)
        if c0 < 0:
            _raise_unclosed(what, start)
        else:
            needs_comma[0] = True
            break

    return c0


# USES GIL!
cdef boolean _unicode_append(
    PyObject **buf_,
    Py_ssize_t *pos_,
    Py_ssize_t *length_,
    Py_UCS4 character
) nogil except False:
    cdef Py_UCS4 ucs4
    cdef Py_UCS4 *data
    cdef PyObject *buf = buf_[0]
    cdef Py_ssize_t pos = pos_[0]
    cdef Py_ssize_t length = length_[0]

    if buf is NULL:
        ucs4 = 0x10FFFF
        buf = UnicodeFromKindAndData(PyUnicode_4BYTE_KIND, &ucs4, 1)
        length = 1

    if pos == length:
        if length <= 0:
            length = 16
        else:
            length *= 2
        UnicodeResize(&buf, length)

    data = <Py_UCS4*> &((<CompactUnicodeObject*> buf)[1])
    data[pos] = character
    pos += 1

    buf_[0] = buf
    pos_[0] = pos
    length_[0] = length
    return True


cdef unicode _decode_identifier_name(ReaderRef reader, uint32_t *c_in_out):
    cdef int32_t c0
    cdef uint32_t c1
    cdef Py_ssize_t start

    cdef PyObject *buf = NULL
    cdef Py_ssize_t pos = 0
    cdef Py_ssize_t length = 0

    start = _reader_tell(reader)
    try:
        c1 = c_in_out[0]
        if not _is_identifier_start(c1):
            _raise_expected_s('IdentifierStart', _reader_tell(reader), c1)

        _unicode_append(&buf, &pos, &length, c1)

        while True:
            if not _reader_good(reader):
                _raise_unclosed('IdentifierName', start)

            c1 = _reader_get(reader)
            if not _is_identifier_part(c1):
                c1 = cast_to_int32(c1)
                break

            _unicode_append(&buf, &pos, &length, c1)

        if pos < length:
            UnicodeResize(&buf, pos)

        c_in_out[0] = c1
        return <unicode> buf
    finally:
        XDecRef(buf)


cdef dict _decode_object(ReaderRef reader):
    cdef int32_t c0
    cdef uint32_t c1
    cdef Py_ssize_t start
    cdef boolean needs_comma
    cdef object key
    cdef object value
    cdef dict result = {}

    start = _reader_tell(reader)
    needs_comma = False
    while True:
        c0 = _skip_comma(reader, start, &needs_comma, <unsigned char>b'}', 'object')
        if c0 < 0:
            break

        c1 = cast_to_uint32(c0)
        if c1 in b'"\'':
            key = _decode_string(reader, c1)
            c0 = _skip_to_data(reader)
        else:
            key = _decode_identifier_name(reader, &c1)
            c0 = _skip_to_data_sub(reader, c1)

        if c0 < 0:
            _raise_unclosed('object', start)

        c1 = cast_to_uint32(c0)
        if c1 != b':':
            _raise_expected_s('colon', _reader_tell(reader), c1)

        c0 = _skip_to_data(reader)
        if c0 < 0:
            _raise_unclosed('object', start)

        c1 = cast_to_uint32(c0)
        value = _decode_recursive(reader, c1)

        result[key] = value
    return result


cdef list _decode_array(ReaderRef reader):
    cdef int32_t c0
    cdef uint32_t c1
    cdef Py_ssize_t start
    cdef boolean needs_comma
    cdef list result = []
    cdef object datum

    start = _reader_tell(reader)
    needs_comma = False
    while True:
        c0 = _skip_comma(reader, start, &needs_comma, <unsigned char>b']', 'array')
        if c0 < 0:
            break
        c1 = cast_to_uint32(c0)

        datum = _decode_recursive(reader, c1)
        result.append(datum)
    return result


cdef boolean _accept_string(ReaderRef reader, const char *string) except False:
    cdef uint32_t c0
    cdef uint32_t c1
    cdef Py_ssize_t start

    start = _reader_tell(reader)
    while True:
        c0 = string[0]
        string += 1
        if not c0:
            break

        if not _reader_good(reader):
            _raise_unclosed('literal', start)

        c1 = _reader_get(reader)
        if c0 != c1:
            _raise_expected_c(c0, start, c1)

    return True


cdef object CONST_POS_NAN = float('+NaN')
cdef object CONST_POS_INF = float('+Infinity')
cdef object CONST_NEG_NAN = float('-NaN')
cdef object CONST_NEG_INF = float('-Infinity')


cdef object _decode_literal(ReaderRef reader, uint32_t c0):
    cdef const char *tail
    cdef object result

    if c0 == b'n':
        tail = b'ull'
        result = None
    elif c0 == b't':
        tail = b'rue'
        result = True
    elif c0 == b'f':
        tail = b'alse'
        result = False
    elif c0 == b'I':
        tail = b'nfinity'
        result = CONST_POS_INF
    else:  # elif c0 == b'N':
        tail = b'aN'
        result = CONST_POS_NAN

    _accept_string(reader, tail)
    return result


cdef object _decode_recursive_enter(ReaderRef reader, uint32_t c0):
    cdef object result

    _reader_enter(reader)
    try:
        if c0 == b'{':
            result = _decode_object(reader)
        else:
            result = _decode_array(reader)
    finally:
        _reader_leave(reader)

    return result


cdef object _decoder_unknown(ReaderRef reader, uint32_t c0):
    raise Json5IllegalCharacter(f'Illegal character U+{c0:04X} near {_reader_tell(reader)}')


cdef object _decode_recursive(ReaderRef reader, uint32_t c0):
    cdef object (*fun)(ReaderRef, uint32_t)

    if c0 in b'ntfIN':
        fun = _decode_literal
    elif c0 in b'\'"':
        fun = _decode_string
    elif c0 in b'+-.0123456789':
        fun = _decode_number
    elif c0 in b'{[':
        fun = _decode_recursive_enter
    else:
        fun = _decoder_unknown

    return fun(reader, c0)


cdef boolean _expect_exhausted(ReaderRef reader) except False:
    cdef Py_ssize_t start
    cdef int32_t c0
    cdef uint32_t c1

    start = _reader_tell(reader)
    c0 = _skip_to_data(reader)
    if c0 >= 0:
        c1 = cast_to_uint32(c0)
        _raise_extra_data(c1, _reader_tell(reader))

    return True


cdef object _decode_all(ReaderRef reader):
    cdef Py_ssize_t start
    cdef int32_t c0
    cdef uint32_t c1
    cdef object result

    start = _reader_tell(reader)
    c0 = _skip_to_data(reader)
    if c0 < 0:
        _raise_no_data(start)
    c1 = cast_to_uint32(c0)

    result = _decode_recursive(reader, c1)
    _expect_exhausted(reader)
    return result


cdef object _decode_ucs1(const Py_UCS1 *string, Py_ssize_t length, Py_ssize_t max_depth):
    cdef ReaderUCS1 reader = ReaderUCS1(string, length, 0, max_depth)
    return _decode_all(reader)


cdef object _decode_ucs2(const Py_UCS2 *string, Py_ssize_t length, Py_ssize_t max_depth):
    cdef ReaderUCS2 reader = ReaderUCS2(string, length, 0, max_depth)
    return _decode_all(reader)


cdef object _decode_ucs4(const Py_UCS4 *string, Py_ssize_t length, Py_ssize_t max_depth):
    cdef ReaderUCS4 reader = ReaderUCS4(string, length, 0, max_depth)
    return _decode_all(reader)


cdef object _decode_unicode(object data, Py_ssize_t max_depth):
    cdef Py_ssize_t length
    cdef int kind

    PyUnicode_READY(data)

    length = PyUnicode_GET_LENGTH(data)
    kind = PyUnicode_KIND(data)

    if kind == PyUnicode_1BYTE_KIND:
        return _decode_ucs1(PyUnicode_1BYTE_DATA(data), length, max_depth)
    elif kind == PyUnicode_2BYTE_KIND:
        return _decode_ucs2(PyUnicode_2BYTE_DATA(data), length, max_depth)
    else:  # elif kind == PyUnicode_4BYTE_KIND:
        return _decode_ucs4(PyUnicode_4BYTE_DATA(data), length, max_depth)


cdef object _decode_latin1(object data, Py_ssize_t max_depth):
    cdef char *string
    cdef Py_ssize_t length

    PyBytes_AsStringAndSize(data, &string, &length)
    return _decode_ucs1(<const Py_UCS1*> string, length, max_depth)