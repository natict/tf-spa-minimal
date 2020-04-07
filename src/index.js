const util = require('util');

const AWS = require('aws-sdk');
const s3 = new AWS.S3();

const defaultPath = "/index.html";

function getParameterCaseInsensitive(object, key, default_value="") {
    let actual_key = Object.keys(object).find(k => k.toLowerCase() === key.toLowerCase());
    return actual_key ? object[actual_key] : default_value;
}

function error_response(code, message) {
    return {
        statusCode: code,
        headers: {
            "content-type": "application/json"
        },
        body: JSON.stringify({
            message: message
        })
    };
}

async function response_from_s3(domainPrefix, path, method, event) {
    let data;
    let headers = {};
    let response = {
        statusCode: 200
    };
    const params = {
        Bucket: process.env['S3_BUCKET'],
        Key: domainPrefix + path,
    };
    try {
        if (method === 'GET') {
            data = await s3.getObject(params).promise();
            response.body = Buffer.from(data.Body).toString("base64");
            response.isBase64Encoded = true;
        } else if (method === 'HEAD') {
            data = await s3.headObject(params).promise();
            headers["Content-Length"] = data.ContentLength.toString();
        } else {
            return error_response(501, util.format("Not Implemented (%s)", method));
        }

        response.headers = {
            ...{
                "Content-Type": data.ContentType,
                "ETag": data.ETag,
                "Last-Modified": data.LastModified
            }, ...headers
        };

        return response;
    } catch (e) {
        return error_response(404, util.format("%s: %s", params.Key, e.message));
    }
}

exports.handler = async (event) => {
    let domainPrefix = getParameterCaseInsensitive(event.headers, 'host').split('.')[0];
    let path = event.path;
    let method = event.httpMethod;
    let response;

    domainPrefix = process.env[domainPrefix] || domainPrefix;  // Use mapping from environment

    response = await response_from_s3(domainPrefix, path, method, event);

    if (response.statusCode === 404 && path !== defaultPath) {
        response = await response_from_s3(domainPrefix, defaultPath, method, event);
    }

    return response;
};