def pax_generic(pax_headers, encoding):
    binary = False
    for keyword, value in pax_headers.items():
        try:
            value.encode("utf-8", "strict")
        except UnicodeEncodeError:
            binary = True
    records = b""
    if binary:
        records += b"21 hdrcharset=BINARY\n"
    return records
