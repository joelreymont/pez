import re


def for_body_listcomp(actions, s):
    result = []
    for i in range(len(actions), 0, -1):
        actions_slice = actions[:i]
        pattern = ''.join([str(x) for x in actions_slice])
        match = re.match(pattern, s)
        if match is not None:
            result.extend([len(x) for x in match.groups()])
            break
    return result
