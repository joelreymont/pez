def merge_segments(segments, exif=b''):
    if segments[1][0:2] == b'\xff\xe0' and segments[2][0:2] == b'\xff\xe1' and segments[2][4:10] == b'Exif\x00\x00':
        if exif:
            segments[2] = exif
            segments.pop(1)
        elif exif is None:
            segments.pop(2)
        else:
            segments.pop(1)
    elif segments[1][0:2] == b'\xff\xe0':
        if exif:
            segments[1] = exif
    elif segments[1][0:2] == b'\xff\xe1' and segments[1][4:10] == b'Exif\x00\x00':
        if exif:
            segments[1] = exif
        elif exif is None:
            segments.pop(1)
    return b''.join(segments)
