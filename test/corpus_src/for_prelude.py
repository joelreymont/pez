def xor_bytes(data, pad):
    xpad = pad
    xdata = data[0:2]
    for i in range(2, len(data)):
        xdata += bytes([data[i] ^ xpad[i - 2]])
    return xdata
