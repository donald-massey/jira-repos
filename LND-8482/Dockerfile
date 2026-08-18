FROM python:3.11-slim-bullseye

# ODBC Driver 17 + build deps for pikepdf (libqpdf) and Pillow (libtiff)
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        curl gnupg2 apt-transport-https \
        unixodbc unixodbc-dev \
        libqpdf-dev \
        libtiff5 \
    && curl https://packages.microsoft.com/keys/microsoft.asc \
       | gpg --dearmor > /usr/share/keyrings/microsoft-prod.gpg \
    && curl https://packages.microsoft.com/config/debian/11/prod.list \
       > /etc/apt/sources.list.d/mssql-release.list \
    && apt-get update \
    && ACCEPT_EULA=Y apt-get install -y msodbcsql17 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY maintenance/ maintenance/
COPY utils/ utils/

ENTRYPOINT ["python", "-m", "maintenance.repair_from_report"]
