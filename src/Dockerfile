FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY highway ./highway
ENV PYTHONUNBUFFERED=1
# One image, many roles: the Deployment picks the module.
CMD ["python", "-m", "highway.executor"]
