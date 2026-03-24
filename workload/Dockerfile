FROM public.ecr.aws/lambda/python:3.12
COPY requirements.txt ${LAMBDA_TASK_ROOT}/
RUN pip install --no-cache-dir -r ${LAMBDA_TASK_ROOT}/requirements.txt
COPY app.py handler.py generate_dataset.py ${LAMBDA_TASK_ROOT}/
# Remove the ENTRYPOINT line
CMD ["handler.lambda_handler"]
