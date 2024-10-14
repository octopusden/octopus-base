
# REST API Guidelines

## Table of Contents
1. [Basic Requirements](#basic-requirements)
    1. [API Base Path](#api-base-path)
    2. [Documentation Generation with OpenAPI](#documentation-generation-with-openapi)
    3. [HTTP Methods for CRUD Operations](#http-methods-for-crud-operations)
    4. [Use Plural Nouns for Resource Names](#use-plural-nouns-for-resource-names)
    5. [Use Query Parameters for Filtering, Sorting, and Pagination](#use-query-parameters-for-filtering-sorting-and-pagination)
    6. [HTTP Status Codes](#http-status-codes)
    7. [Handle Errors Gracefully](#handle-errors-gracefully)
    8. [Use JSON for Responses](#use-json-for-responses)
2. [Specific Cases](#specific-cases)
    1. [Use POST for Complex Search Operations](#use-post-for-complex-search-operations)
    2. [Sub-Resources and Actions](#sub-resources-and-actions)
3. [REST Operations Attributes](#rest-operations-attributes)
    1. [Statelessness](#statelessness)
    2. [Idempotency](#idempotency)

## 1. Basic Requirements

### 1.1 API Base Path
**Format**: `/rest/api/{api-version}`

The base path should always start with `/rest/api/` followed by the API version number to maintain consistency and clarity across different versions.

**Example**: `/rest/api/3`

### 1.2 Documentation Generation with OpenAPI
Use Swagger to render interactive API documentation.

**Examples**:
- [Swagger UI for DMS Service](https://<domain.corp>/dms-service/swagger-ui/index.html)
- [API Docs for Employee Service](https://<domain.corp>/employee-service/v3/api-docs)

### 1.3 HTTP Methods for CRUD Operations
Each HTTP method corresponds to a specific type of action:

- **GET**: Retrieve data from the server (e.g., fetch a user or a list of components).
- **POST**: Create a new resource on the server (e.g., add a new user).
- **PUT**: Update an existing resource (e.g., update user details).
- **PATCH**: Partially update a resource (e.g., update only a specific field).
- **DELETE**: Remove a resource (e.g., delete a user).

### 1.4 Use Plural Nouns for Resource Names
Plural nouns are more intuitive for resources that represent collections.

**Good**: `/components`, `/users`  
**Bad**: `/user`, `/product`

**Example**:  
`/rest/api/3/components/{component-name}/versions/{version}`

### 1.5 Use Query Parameters for Filtering, Sorting, and Pagination
- **Filtering**: `/rest/api/1/components?type=external`
- **Sorting**: `/rest/api/1/components?sort=created_at`
- **Pagination**: `/rest/api/1/?page=2&limit=20`

### 1.6 HTTP Status Codes
Use standard HTTP status codes to indicate the result of the request:
- **200 OK**: Successful GET or PUT request.
- **201 Created**: Successful POST request, resource created.
- **204 No Content**: Successful DELETE request with no content to return.
- **400 Bad Request**: The request is malformed.
- **401 Unauthorized**: Authentication is required or failed.
- **403 Forbidden**: The client does not have permission.
- **404 Not Found**: Resource not found.
- **500 Internal Server Error**: Server error.

### 1.7 Handle Errors Gracefully
Return meaningful error messages in a consistent format:

\`\`\`json
{
  "error": {
    "code": 404,
    "message": "User not found"
  }
}
\`\`\`

### 1.8 Use JSON for Responses
Use camelCase for field names in JSON.

\`\`\`json
{
  "id": "my-component",
  "componentOwner": "John",
  "releasesInDefaultBranch": true,
  "buildSystem": "MAVEN"
}
\`\`\`

## 2. Specific Cases

### 2.1 Use POST for Complex Search Operations
Use POST when queries involve sending complex data that doesn't fit neatly into query parameters, such as extensive search criteria or bulk operations.

**Example**:
\`\`\`http
POST /artifacts/search 
\`\`\`

**JSON Body**:
\`\`\`json
{ 
    "repositoryType": "DEBIAN", 
    "deb": "pool/s/some-app/some-app_0.1.2-3_amd64.deb"
}
\`\`\`

### 2.2 Sub-Resources and Actions

**Format**: `/components/{component-name}/versions/{version}/{sub-resource}`

For resources that belong to a parent entity (like versions of a component), the URL should reflect this hierarchical relationship. Specific actions, such as downloading artifacts, should be clearly described in the endpoint.

**Example**:  
`/rest/api/3/components/example-component/versions/1.0/artifacts/{artifact-id}/download`

## 3. REST Operations Attributes

### 3.1 Statelessness
REST APIs should be stateless, meaning each request from the client to the server must contain all the necessary information to understand and complete the request. The server should not store client context.

### 3.2 Idempotency
Ensure that certain HTTP methods (like PUT, DELETE, and GET) are idempotent, meaning calling them multiple times with the same parameters should produce the same result.

