#!/usr/bin/env bash

set -euf -o pipefail

SCRIPT_PATH="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

PROMPT_PREFIX=">>"
TMP_DIR="$(pwd)/.tmp"

LAMBDA_CODE_PATH="lambda_code"
INDEX_TEMPLATE="index.js.template"
INDEX_FILE="${INDEX_TEMPLATE%.*}"
SOURCE_INDEX_TEMPLATE="${SCRIPT_PATH}/${LAMBDA_CODE_PATH}/${INDEX_TEMPLATE}"
OUTPUT_INDEX_TEMPLATE="${TMP_DIR}/${INDEX_FILE}"

NODE_MODULES_DIR="node_modules"
SOURCE_NODE_MODULES_DIR="${SCRIPT_PATH}/${LAMBDA_CODE_PATH}/${NODE_MODULES_DIR}"
OUTPUT_NODE_MODULES_DIR="${TMP_DIR}/${NODE_MODULES_DIR}"

DATE=$(date +%Y%m%d%H%M)
LAMBDA_ARCHIVE_FILE_PATH="${TMP_DIR}/${DATE}.zip"

CORS_CONFIGURATION_FILE_NAME="cors_configuration.json"
CORS_CONFIGURATION_FILE_PATH="${TMP_DIR}/${CORS_CONFIGURATION_FILE_NAME}"
CORS_CONFIGURATION_CONTENT='
{
  "CORSRules": [
    {
      "AllowedOrigins": ["http*"],
      "AllowedHeaders": ["*"],
      "AllowedMethods": ["HEAD", "GET", "PUT", "POST", "DELETE"],
      "ExposeHeaders": ["x-amz-server-side-encryption", "ETag", "x-amz-meta-custom-header"]
    }
  ]
}
'

AWS_REGION="us-east-1"
STACK_PREFIX="private-website"
CF_TEMPLATE_FILE_NAME="cf_template.yml"
CF_TEMPLATE_FILE_PATH="${SCRIPT_PATH}/${CF_TEMPLATE_FILE_NAME}"

source ${SCRIPT_PATH}/mo

function prompt {
	echo -n "${PROMPT_PREFIX} $@ " 1>&2
}

function info {
	echo "INFO  | $1" 1>&2
}

function die {
	EXIT_CODE=$?
	if [ "$EXIT_CODE" -eq "0" ]; then
		EXIT_CODE=1
	fi
	echo "ERROR | $1" 1>&2
	exit ${EXIT_CODE}
}

function validate_tools {
	which ssh-keygen > /dev/null || die "Required ssh-keygen not found."
	which openssl > /dev/null || die "Required openssl not found."
	which zip > /dev/null || die "Required zip not found."
	which aws > /dev/null || die "Required aws cli not found. See https://docs.aws.amazon.com/cli/latest/userguide/installing.html to install."
}

function gather_input {
	prompt "Client ID:"
	read CLIENT_ID
	prompt "Client Secret:"
	read CLIENT_SECRET
	prompt "Redirect URI:"
	read REDIRECT_URI
	prompt "Hosted domain:"
	read HOSTED_DOMAIN
	prompt "Endpoint URL for json lookup (leave blank if not used):"
	read JSON_EMAIL_LOOKUP
	prompt "Session duration (seconds):"
	read SESSION_DURATION

	echo "$PROMPT_PREFIX Authorization methods:" 1>&2
	echo "$PROMPT_PREFIX     (1) Hosted Domain - verify email's domain matches that of the given hosted domain" 1>&2
	echo "$PROMPT_PREFIX     (2) HTTP Email Lookup - verify email exists in JSON array located at given HTTP endpoint" 1>&2
	prompt "Select an authorization method: " 1>&2
	read AUTH_METHOD_INDEX

	case "${AUTH_METHOD_INDEX}" in
	        1)
	            AUTH_METHOD="domain"
	            ;;
	        2)
	            AUTH_METHOD="json-lookup"
	            ;;
	        *)
	            die "Invalid auth method selected"
	esac

    echo "${CLIENT_ID}|${CLIENT_SECRET}|${REDIRECT_URI}|${HOSTED_DOMAIN}|${JSON_EMAIL_LOOKUP}|${SESSION_DURATION}|${AUTH_METHOD}"
}

function reset_temp_dir {
	rm -rf ${TMP_DIR}
	mkdir -p ${TMP_DIR}
}

function extract_callback_path {
	local URL=$1
	local URL_NOPRO=$(echo $URL | sed -e 's/^http:\/\///g' -e 's/^https:\/\///g')
	local URL_REL=${URL_NOPRO#*/}
	echo "/${URL_REL%%\?*}"
}

function create_keys {
	ssh-keygen -t rsa -b 4096 -f ${TMP_DIR}/id_rsa -q -N '' || die "Failed to generate private key"
	local PRIVATE_KEY=$(cat ${TMP_DIR}/id_rsa | sed 's/$/\\\\n/' | tr -d '\n')

	openssl rsa -in ${TMP_DIR}/id_rsa -pubout -outform PEM -out ${TMP_DIR}/id_rsa.pub 2> /dev/null || die "Failed to generate public key"
	local PUBLIC_KEY=$(cat ${TMP_DIR}/id_rsa.pub | sed 's/$/\\\\n/' | tr -d '\n' )

	echo "${PRIVATE_KEY}|${PUBLIC_KEY}"
}

function get_s3_bucket {
    local PROMPT_MSG="$@"

	prompt ${PROMPT_MSG}
	read S3_BUCKET

    echo "${S3_BUCKET}"
}

function validate_s3_bucket {
	local S3_BUCKET=$1

	if ! aws s3api head-bucket --bucket "${S3_BUCKET}" 2> /dev/null;  then
		info "Creating S3 bucket: ${S3_BUCKET}"
    	aws s3 mb s3://${S3_BUCKET}/ --region ${AWS_REGION} || die "Failed to create S3 bucket ${S3_BUCKET}"
    fi
}

function main {
    validate_tools

	reset_temp_dir || die "Failed to recreate temporary directory ${TMP_DIR}"

	info "Gathering necessary details:"
    echo "" 1>&2
	IFS='|' read PRIVATE_KEY PUBLIC_KEY < <(create_keys)
	IFS='|' read CLIENT_ID CLIENT_SECRET REDIRECT_URI HOSTED_DOMAIN JSON_EMAIL_LOOKUP SESSION_DURATION AUTH_METHOD < <(gather_input)
	S3_BUCKET=$(get_s3_bucket "Enter the S3 bucket to expose (if it doesn't exist it will be created): ")
	LAMBDA_S3_BUCKET=$(get_s3_bucket "Enter the S3 bucket for the AWS Lambda zip bundle (if it doesn't exist it will be created): ")
	CALLBACK_PATH=$(extract_callback_path $REDIRECT_URI)
    echo "" 1>&2

    validate_s3_bucket ${S3_BUCKET}
    validate_s3_bucket ${LAMBDA_S3_BUCKET}

    info "Creating temporary files in: ${TMP_DIR}"
	mo ${SOURCE_INDEX_TEMPLATE} > ${OUTPUT_INDEX_TEMPLATE} || die "Failed to generate index file"
	cp -r ${SOURCE_NODE_MODULES_DIR} ${OUTPUT_NODE_MODULES_DIR} || die "Failed to copy node modules"

    info "Creating zip file: ${LAMBDA_ARCHIVE_FILE_PATH}"
    pushd ${TMP_DIR} > /dev/null || die "Failed to cd into temporary directory"
	zip -q ${LAMBDA_ARCHIVE_FILE_PATH} ${INDEX_FILE} -r ${NODE_MODULES_DIR} || die "Failed to create zip file"
	popd > /dev/null || die "Failed to return to original directory"

    LAMBDA_ARCHIVE_S3_PATH="s3://${LAMBDA_S3_BUCKET}/${DATE}.zip"
	info "Uploading AWS Lambda zip archive to: ${LAMBDA_ARCHIVE_S3_PATH}"
	aws s3 cp ${LAMBDA_ARCHIVE_FILE_PATH} ${LAMBDA_ARCHIVE_S3_PATH} \
	    --region ${AWS_REGION} > /dev/null || die "Uploading AWS Lambda zip archive"

	info "Updating cors configuration for bucket: ${S3_BUCKET}"
	echo ${CORS_CONFIGURATION_CONTENT} > ${CORS_CONFIGURATION_FILE_PATH} || die "Writing temporary cors configuration"
	aws s3api put-bucket-cors \
	    --bucket ${S3_BUCKET} \
	    --cors-configuration file://${CORS_CONFIGURATION_FILE_PATH} \
	    --region ${AWS_REGION} || die "Updating cors configuration"

    STACK_NAME="${STACK_PREFIX}-${S3_BUCKET}"
	info "Creating AWS CloudFormation stack with name: ${STACK_NAME}"
	aws cloudformation deploy \
	    --stack-name ${STACK_NAME} \
	    --template-file file://${CF_TEMPLATE_FILE_PATH} \
	    --parameter-overrides DomainName=${HOSTED_DOMAIN} \
	                          S3Bucket=${S3_BUCKET} \
	                          LambdaArchiveS3Bucket=${LAMBDA_S3_BUCKET} \
	                          LambdaArchiveName=${DATE}.zip \
	    --capabilities CAPABILITY_IAM \
	    --region ${AWS_REGION} > /dev/null || die "Failed to create CloudFormation stack"

	CLOUDFRONT_AWS_URL=$(aws cloudformation describe-stacks \
	                         --stack-name ${STACK_NAME} \
	                         --query 'Stacks[0].Outputs[?OutputKey==`CloudFrontDistribution`].OutputValue' \
	                         --output text \
	                         --region ${AWS_REGION} || die "Failed to retrieve CloudFront AWS URL")
	SITE_URL=$(aws cloudformation describe-stacks \
	               --stack-name ${STACK_NAME} \
	               --query 'Stacks[0].Outputs[?OutputKey==`SiteURL`].OutputValue' \
	               --output text \
	               --region ${AWS_REGION} || die "Failed to retrieve Site URL")

    info "Waiting for CloudFormation stack completion"
	aws cloudformation wait stack-create-complete --stack-name ${STACK_NAME} --region ${AWS_REGION}

    info "The website is available at: ${SITE_URL}"
    info "If you require HTTPS access to the site change the SSL certificate for the CloudFront distribution here: ${CLOUDFRONT_AWS_URL}"
}

main
