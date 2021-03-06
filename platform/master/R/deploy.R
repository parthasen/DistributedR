#####################################################################
#A scalable and high-performance platform for R.
#Copyright (C) [2013] Hewlett-Packard Development Company, L.P.

#This program is free software; you can redistribute it and/or modify
#it under the terms of the GNU General Public License as published by
#the Free Software Foundation; either version 2 of the License, or (at
#your option) any later version.

#This program is distributed in the hope that it will be useful, but
#WITHOUT ANY WARRANTY; without even the implied warranty of
#MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
#General Public License for more details.  You should have received a
#copy of the GNU General Public License along with this program; if
#not, write to the Free Software Foundation, Inc., 59 Temple Place,
#Suite 330, Boston, MA 02111-1307 USA
#####################################################################

## Function to deploy an R object (mainly) a model into a Vertica database.
# model: A valid R model to be deployed
# dsn: ODBC DSN name
# modelName: Name with which the model will be saved in Vertica db

deploy.model <- function(model, dsn, modelName, modelComments="", localTmpFilePath = '/tmp') {

   if(missing(model))
     stop("R model to be deployed is missing")
   if(missing(dsn) || !is.character(dsn))
     stop("data source name for connecting to Vertica database is missing or invalid")
   if(missing(modelName))
     stop("model name is missing")
   if(!is.character(modelName) || gregexpr('^[a-z_][a-z0-9_]*$', modelName[[1]], ignore.case=TRUE) < 0 || nchar(modelName[[1]]) > 256)
      stop("invalid model name")
   if(!is.character(modelComments) || nchar(modelComments[[1]]) > 2048)
     stop("invalid model description")
   
   S <- distributedR_status()
   
   modelName <- modelName[[1]]
   modelComments <- modelComments[[1]]
   
   # Get model type
   modelType <- .get.modeltype(class(model))

   if (inherits(model, "glm") || inherits(model, "hpdglm")) {
     isInvalidGlm <- ifelse(is.null(model$call$completeModel), FALSE, model$call$completeModel)
     if(isInvalidGlm)
       stop("Model generated with completeModel=TRUE cannot be deployed to Vertica. \n  Re-run hpdglm() with completeModel=FALSE")

     family <- model$family$family
     link <- model$family$link

     if(is.null(family) || is.null(link))
       print("Warning: glm model is missing family or link.")
     else
       modelType <- paste(modelType, " [family(", family, "), link(", link, ")]", sep="")
   } 
   else if (inherits(model, "randomForest") || inherits(model, "hpdrandomForest")) {
     isInvalidRF <- ifelse(is.null(model$call$completeModel), FALSE, model$call$completeModel)
     if(isInvalidRF)
       stop("Model generated with completeModel=TRUE cannot be deployed to Vertica. \n  Re-run hpdrandomForest() with completeModel=FALSE")
 
     type <- model$type
       
     if(is.null(type))
       print("Warning: randomForest model is missing type.")
     else
       modelType <- paste(modelType, " [type(", type, ")]", sep="")
   } 
   else if (inherits(model, "hpdkmeans") && !is.null(model$cluster)) {
     stop("Model generated with completeModel=TRUE cannot be deployed to Vertica. \n  Re-run hpdkmeans() with completeModel=FALSE")
     #stop("Model has darray components and cannot be deployed to Vertica. \n  Re-run hpdkmeans() with completeModel=FALSE")
   }
   
   if (! require(vRODBC) )
        library(RODBC)

   # connecting to Vertica
   db_connect <- odbcConnect(dsn)

   ## Create table R_Models
   tableName <- "R_models"
   schema <- "public"
   .create.metadata.table(schema, tableName, db_connect)

   #get current user
   user <- sqlQuery(db_connect, "select user();")
   if(!is.data.frame(user)) {
     odbcClose(db_connect)
     stop(user)
   }      

   # check if model name is unique
   modelPath <- paste(user[[1]][[1]], "/", modelName, sep="")
   qryString <- paste("select count(*) from ", schema, ".", tableName, " where model ilike '", modelPath, "';", sep="")

   existsModel <- sqlQuery(db_connect, qryString)
   if(!is.data.frame(existsModel)) {
     odbcClose(db_connect)
     stop(existsModel)
   } else if(existsModel > 0) {
     odbcClose(db_connect)
     stop(paste("User '", user[[1]][[1]], "' has a model deployed in Vertica with same name '", modelName, "'", sep=""))
   } else {
     # serialize model to a file
     .serialize.obj <- rawToChar(serialize(model, NULL, ascii=T))
     local_tmp_file <- tempfile(pattern = Sys.getenv("USER"), tmpdir = localTmpFilePath, fileext = '.rmodel')
     write(.serialize.obj, file=local_tmp_file)

     current_time <- Sys.time()
     modelSize <- file.info(local_tmp_file)$size
     #Call COPY command to pass the model to Vertica
     qryString <- paste("COPY ", schema, ".", tableName, " FROM LOCAL '", local_tmp_file, "' WITH PARSER public.DeployModelToVertica(model_name='", modelName, "', model_type='", modelType,"', model_description='", modelComments ,"', model_size=", modelSize, ", user_name='", user[[1]][[1]], "', timestamp='", current_time, "');", sep="")
     deploy_model <- sqlQuery(db_connect, qryString)

     if(length(deploy_model) > 0L) {
       unlink(local_tmp_file)
       odbcClose(db_connect)
       stop(.Call("HandleUDxError", deploy_model))
       FALSE
     }
     unlink(local_tmp_file)

     # Check for duplicate models again because Vertica does not enforce PK
     qryString <- paste("select count(*) from ", schema, ".", tableName, " where model = '", modelPath, "';", sep="")
     duplicateModel <- sqlQuery(db_connect, qryString)
     if(!is.data.frame(duplicateModel)) {
       odbcClose(db_connect)
       stop(duplicateModel)
     } else if(duplicateModel > 1) {
       #Delete both models and give an error
       qryString <- paste("select public.DeleteModel( USING PARAMETERS model='", modelPath, "') over();", sep="")
       deleteDuplicate <- sqlQuery(db_connect, qryString)
     }
     
   }
   
   odbcClose(db_connect)
   TRUE
}


.get.modeltype <- function(model_type) {
    supported_models <- c("glm", "hpdglm",
                          "kmeans", "hpdkmeans",
                          "randomForest", "hpdrandomForest")
    model_type_str <- paste(model_type, collapse=", ")

    if(! any(model_type %in% supported_models)) 
      stop(paste("Unsupported type:", model_type_str))

    model_type[[1]]
}

.create.metadata.table <- function(schema, tableName, db_connect) {
    qryString <- paste("select column_name, data_type from columns where table_schema ilike '", schema, "' and table_name ilike '", tableName, "';", sep="");
    columns <- sqlQuery(db_connect, qryString)

    if (!is.data.frame(columns)) {
      odbcClose(db_connect)
      stop(columns)
    }

    if (nrow(columns) == 0) {
      qryString <- paste("CREATE TABLE IF NOT EXISTS ", schema, ".", tableName, "(model varchar(512) PRIMARY KEY, owner varchar(256), model_type varchar(256), description varchar(2048), size int, deploy_time timestampTz);", sep="")
      sqlQuery(db_connect, qryString)
    } else
    {
      # Check if column names/type/size match with the existing table. 
      # If not, error is returned.
      expected_defn <- params <- data.frame(column_name=rep(NA, 6), data_type=rep(NA, 6))
      expected_defn$column_name <- as.factor(c("model", "owner", "model_type", "description", "size", "deploy_time"))
      expected_defn$data_type <- as.factor(c("varchar(512)", "varchar(256)", "varchar(256)", "varchar(2048)", "int", "timestamptz"))

      if(!identical(columns, expected_defn)) {
         odbcClose(db_connect)
         stop(paste("A table '", tableName, "' exists in the database with incompatible definition.\n  Remove the table and re-try.", sep=""))
      }
    }
}

