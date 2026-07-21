"""Upload LND-7761 review sheet to OneDrive via Microsoft Graph API."""
import sys
import requests
import msal

CLIENT_ID = "14d82eec-204b-4c2f-b7e8-296a70dab67e"  # Microsoft Graph Explorer public client
AUTHORITY = "https://login.microsoftonline.com/common"
SCOPES = ["Files.ReadWrite"]

LOCAL_FILE = r"C:\Users\donald.massey\PycharmProjects\LND-7761\reviews\LND-7761_review_Donald_Massey.xlsx"
UPLOAD_NAME = "LND-7761_repo_review.xlsx"


def get_token():
    app = msal.PublicClientApplication(CLIENT_ID, authority=AUTHORITY)
    flow = app.initiate_device_flow(scopes=SCOPES)
    if "user_code" not in flow:
        raise RuntimeError(f"Failed to create device flow: {flow}")
    print(flow["message"])
    result = app.acquire_token_by_device_flow(flow)
    if "access_token" not in result:
        raise RuntimeError(f"Auth failed: {result.get('error_description', result)}")
    return result["access_token"]


def upload_file(token):
    with open(LOCAL_FILE, "rb") as f:
        data = f.read()

    url = f"https://graph.microsoft.com/v1.0/me/drive/root:/{UPLOAD_NAME}:/content"
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    }
    resp = requests.put(url, headers=headers, data=data)
    resp.raise_for_status()
    item = resp.json()
    print(f"\nUploaded: {item['name']}")
    print(f"OneDrive URL: {item['webUrl']}")
    return item


if __name__ == "__main__":
    try:
        token = get_token()
        upload_file(token)
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)
