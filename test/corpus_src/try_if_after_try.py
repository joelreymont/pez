
def upload_file(file, url, retries, delay):
    for attempt in range(retries):
        try:
            files = {'file': file}
            response = requests.post(url, files=files)
            if response.status_code == 200:
                print('File uploaded successfully')
                return True
            else:
                print(f'Failed to upload file: {response.status_code} - {response.text}')
        except requests.RequestException as e:
            print(f'Request failed: {e}')
        time.sleep(delay)
    print('All attempts failed')
    return False
