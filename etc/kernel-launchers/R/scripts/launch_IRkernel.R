library(SparkR)
library(argparser)
library(jsonlite)

require("base64enc")
require("digest")
require("stringr")

r_libs_user <- Sys.getenv("R_LIBS_USER")

sparkConfigList <- list(
spark.executorEnv.R_LIBS_USER=r_libs_user,
spark.rdd.compress="true")

min_port_range_size = Sys.getenv("EG_MIN_PORT_RANGE_SIZE")
if ( is.null(min_port_range_size) )
    min_port_range_size = 1000

# Initializes the Spark session/context and SQL context
initialize_spark_session <- function() {
    # Make sure SparkR package is loaded last; this is necessary
    # to avoid the need to fully qualify package namspace (using ::)
    old <- getOption("defaultPackages")
    options(defaultPackages = c(old, "SparkR"))

    makeActiveBinding(".sparkRsession", sparkSessionFn, SparkR:::.sparkREnv)
    makeActiveBinding(".sparkRjsc", sparkContextFn, SparkR:::.sparkREnv)

    delayedAssign("spark", {get(".sparkRsession", envir=SparkR:::.sparkREnv)}, assign.env=.GlobalEnv)

    # backward compatibility for Spark 1.6 and earlier notebooks
    delayedAssign("sc", {get(".sparkRjsc", envir=SparkR:::.sparkREnv)}, assign.env=.GlobalEnv)
    delayedAssign("sqlContext", {spark}, assign.env=.GlobalEnv)
}

sparkSessionFn <- local({
     function(v) {
       if (missing(v)) {
         # get SparkSession

         # create a new sparkSession
         rm(".sparkRsession", envir=SparkR:::.sparkREnv) # rm to ensure no infinite recursion

         get("sc", envir=.GlobalEnv)

         sparkSession <- SparkR::sparkR.session(
                                        sparkHome=Sys.getenv("SPARK_HOME"),
                                        appName=Sys.getenv("KERNEL_ID"),
                                        sparkConfig=sparkConfigList);
         sparkSession
       }
     }
   })

sparkContextFn <- local({
    function(v) {
      if (missing(v)) {
        # get SparkContext

        # create a new sparkContext
        rm(".sparkRjsc", envir=SparkR:::.sparkREnv) # rm to ensure no infinite recursion

        message ("Obtaining Spark session...")

        sparkContext <- SparkR:::sparkR.sparkContext(
                                          sparkHome=Sys.getenv("SPARK_HOME"),
                                          appName=Sys.getenv("KERNEL_ID"),
                                          sparkEnvirMap=SparkR:::convertNamedListToEnv(sparkConfigList))

        message ("Spark session obtained.")
        sparkContext
      }
    }
  })

encrypt <- function(json, connection_file) {
  # Ensure that the length of the data that will be encrypted is a
  # multiple of 16 by padding with '%' on the right.
  raw_payload <- str_pad(json, (str_length(json) %/% 16 + 1) * 16, side="right", pad="%")
  message(paste("Raw Payload: ", raw_payload))

  fn <- basename(connection_file)
  tokens <- unlist(strsplit(fn, "kernel-"))
  key <- charToRaw(substr(tokens[2], 1, 16))
  # message(paste("AES Encryption Key: ", rawToChar(key)))

  cipher <- AES(key, mode="ECB")
  encrypted_payload <- cipher$encrypt(raw_payload)
  encoded_payload = base64encode(encrypted_payload)
  return(encoded_payload)
}

# Return connection information
return_connection_info <- function(connection_file, response_addr){

  response_parts <- strsplit(response_addr, ":")

  if (length(response_parts[[1]])!=2){
    cat("Invalid format for response address. Assuming pull mode...")
    return(1)
  }

  response_ip <- response_parts[[1]][1]
  response_port <- response_parts[[1]][2]

  # Read in connection file to send back to JKG
  tryCatch(
    {
        con <- socketConnection(host=response_ip, port=response_port, blocking=FALSE, server=FALSE)
        sendme <- read_json(connection_file)
        # Add launcher process id to returned info...
        sendme$pid <- Sys.getpid()
        json <- toJSON(sendme, auto_unbox=TRUE)
        message(paste("JSON Payload: ", json))

        fn <- basename(connection_file)
        if (!grepl("kernel-", fn)) {
          message(paste("Invalid connection file name: ", connection_file))
          return(NA)
        }
        payload <- encrypt(json, connection_file)
        message(paste("Encrypted Payload: ", payload))
        write_resp <- writeLines(payload, con)
    },
    error=function(cond) {
        message(paste("Unable to connect to response address", response_addr ))
        message("Here's the original error message:")
        message(cond)
        # Choose a return value in case of error
        return(NA)
    },
    finally={
        close(con)
    }
  )
}

# Figure out the connection_file to use
determine_connection_file <- function(connection_file){
    # If the directory of the given connection_file exists, use it.
    if (dir.exists(dirname(connection_file))) {
        return(connection_file)
    }
    # Else, create a temporary filename and return that.
    base_file = tools::file_path_sans_ext(basename(connection_file))
    temp_file = tempfile(pattern=paste(base_file,"_",sep=""), fileext=".json")
    cat(paste("Using connection file ",temp_file," instead of ",connection_file," \n",sep="'"))
    return(temp_file)
}

validate_port_range <- function(port_range){
    port_ranges = strsplit(port_range, "..", fixed=TRUE)
    lower_port = as.integer(port_ranges[[1]][1])
    upper_port = as.integer(port_ranges[[1]][2])

    port_range_size = upper_port - lower_port
    if (port_range_size != 0) {
        if (port_range_size < min_port_range_size){
            message(paste("Port range validation failed for range:", port_range, ". Range size must be at least",
                min_port_range_size, "as specified by env EG_MIN_PORT_RANGE_SIZE"))
            return(NA)
        }
    }
    return(list("lower_port"=lower_port, "upper_port"=upper_port))
}

# Check arguments
parser <- arg_parser('R-kernel-launcher')
parser <- add_argument(parser, "--RemoteProcessProxy.port-range",
       help="the range of ports impose for kernel ports")
parser <- add_argument(parser, "--RemoteProcessProxy.response-address",
       help="the IP:port address of the system hosting JKG and expecting response")
parser <- add_argument(parser, "connection_file",
       help="Connection file name to be used; dictated by JKG")

argv <- parse_args(parser)

# If connection file does not exist on local FS, create it.
#  If there is a response address, use pull socket mode
connection_file <- argv$connection_file
if (!file.exists(connection_file)){
    connection_file <- determine_connection_file(connection_file)

    # if port-range was provided, validate the range and determine bounds
    lower_port = 0
    upper_port = 0
    if (!is.na(argv$RemoteProcessProxy.port_range)){
        range <- validate_port_range(argv$RemoteProcessProxy.port_range)
        if (!is.na(range)){
            lower_port = range$lower_port
            upper_port = range$upper_port
        }
    }

    # Get the pid of the launcher so the listener thread (process) can detect its
    # presence to know when to shutdown.
    pid <- Sys.getpid()

    # Hoop to jump through to get the directory this script resides in so that we can
    # load the co-located python gateway_listener.py file.  This code will not work if
    # called directly from within RStudio.
    # https://stackoverflow.com/questions/1815606/rscript-determine-path-of-the-executing-script
    launch_args <- commandArgs(trailingOnly = FALSE)
    file_option <- "--file="
    script_path <- sub(file_option, "", launch_args[grep(file_option, launch_args)])
    listener_file <- paste(sep="/", dirname(script_path), "gateway_listener.py")

    # Launch the gateway listener logic in an async manner and poll for the existence of
    # the connection file before continuing.  Should there be an issue, Enterprise Gateway
    # will terminate the launcher, so there's no need for a timeout.
    python_cmd <- stringr::str_interp(gsub("\n[:space:]*" , "",
               "python -c \"import os, sys, imp;
                gl = imp.load_source('setup_gateway_listener', '${listener_file}');
                gl.setup_gateway_listener(fname='${connection_file}', parent_pid='${pid}', lower_port=${lower_port}, upper_port=${upper_port})\""))
    system(python_cmd, wait=FALSE)

    while (!file.exists(connection_file)) {
        Sys.sleep(0.5)
    }

    if (!is.na(argv$RemoteProcessProxy.response_address)){
      return_connection_info(connection_file, argv$RemoteProcessProxy.response_address)
    }
}

initialize_spark_session()

# Start the kernel
IRkernel::main(connection_file)

unlink(connection_file)

# Stop the context and exit
sparkR.session.stop()
