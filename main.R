library(tercen)
library(tercenApi)
library(dplyr, warn.conflicts = FALSE)
library(jsonlite)

library(tim)

MCR_PATH <- "/opt/mcr/v99"
MATCALL  <- "/mcr/exe/run_plsda.sh"

# MCR_PATH <- "/home/rstudio/mcr/v99"
# MATCALL  <- "/home/rstudio/plsda_exe/run_plsda.sh"
# chmod +x /home/rstudio/plsda_exe/run_plsda.sh C
# chmod +x /home/rstudio/plsda_exe/plsda 
# =============================================
# http://127.0.0.1:5400/test/w/e661aaed87b1878293dbebb15203e6e8/ds/83c25e39-3a03-4f7a-9a61-c71340b4ddb6
# options("tercen.workflowId" = "e661aaed87b1878293dbebb15203e6e8")
# options("tercen.stepId"     = "83c25e39-3a03-4f7a-9a61-c71340b4ddb6")


get_operator_props <- function(ctx, imagesFolder){
  MaxComponents <- -1
  Permutations   <- -1
  
  AutoScale <- "no"
  Bagging <- "None"
  NumberOfBags <- -1
  CrossValidation <- "LOOCV"
  Optimization<- "auto"
  QuantitationType <- "median"
  DiagnosticPlot <- "Advanced"

  
  operatorProps <- ctx$query$operatorSettings$operatorRef$propertyValues
  
  for( prop in operatorProps ){

    if (prop$name == "MaxComponents"){
      MaxComponents <- as.numeric(prop$value)
    }
    
    if (prop$name == "AutoScale"){
      AutoScale <- prop$value
    }
    
    if (prop$name == "Bagging"){
      Bagging <- prop$value
    }
    
    if (prop$name == "NumberOfBags"){
      NumberOfBags <- as.numeric(prop$value)
    }
    
    if (prop$name == "CrossValidation"){
      CrossValidation <- prop$value
    }
    
    if (prop$name == "Optimization"){
      Optimization <- prop$value
    }
    
    if (prop$name == "Diagnostic Plot"){
      DiagnosticPlot <- prop$value
    }
    
  }
  
  if( is.null(DiagnosticPlot) ){
    DiagnosticPlot <- "Advanced"
  }
  

  if( is.null(MaxComponents) || MaxComponents == -1 ){
    MaxComponents <- 3
  }
  
  if( is.null(Permutations) || Permutations == -1 ){
    Permutations <- 0
  }
  
  if( is.null(NumberOfBags) || NumberOfBags == -1 ){
    NumberOfBags <- 24
  }
  
  
  props <- list()
  
  props$MaxComponents <- MaxComponents
  props$Permutations <- Permutations
  
  props$AutoScale <- AutoScale
  props$Bagging <- Bagging
  props$NumberOfBags <- NumberOfBags
  props$CrossValidation <- CrossValidation
  props$Optimization<- Optimization
  props$QuantitationType <- QuantitationType
  props$DiagnosticPlot <- DiagnosticPlot
  

  
  return (props)
}




classify <- function(df, props, arrayColumns, rowColumns, colorColumns){
  outfileMat <- tempfile(fileext = ".mat")
  outfileTxt <- tempfile(fileext = ".txt")
  outfileImg <- tempfile(fileext = ".png")

  
  dfJson = list(list(
    "MaxComponents"=props$MaxComponents, 
    "Permutations"=props$Permutations,
    "AutoScale"=props$AutoScale,
    "Bagging"=props$Bagging,
    "NumberOfBags"=props$NumberOfBags,
    "CrossValidation"=props$CrossValidation,
    "Optimization"=props$Optimization,
    "QuantitationType"=props$QuantitationType,
    "DiagnosticPlot"=props$DiagnosticPlot,
    "DiagnosticPlotPath"=outfileImg,
    "RowFactor"="ID", # "rowColumns[[  length(rowColumns)  ]],
    "ColFactor"=arrayColumns[[ length(arrayColumns) ]],
    "OutputFileMat"=outfileMat, 
    "OutputFileTxt"=outfileTxt )
  )
  
  
  for( arrayCol in arrayColumns ){
    dfJson <- append( dfJson, 
                      list(list(
                        "name"=arrayCol,
                        "type"="Array",
                        "data"=pull(df, arrayCol)
                      ))
    )
  }
  for( rowCol in rowColumns ){
    dfJson <- append( dfJson,
                      list(list(
                        "name"="ID", #rowCol, # Might be multiple....
                        "type"="Spot",
                        "data"=pull(df, rowCol)
                      ))
    )
  }
  
  for( colorCol in colorColumns ){
    dfJson <- append( dfJson,
                      list(list(
                        "name"=colorCol,
                        "type"="color",
                        "data"=pull(df, colorCol)
                      ))
    )
  }
  
  dfJson <- append( dfJson,
                    list(list(
                      "name"="LFC",
                      "type"="value",
                      "data"=pull(df, ".y")
                    ) ))
  
  
  jsonData <- toJSON(dfJson, pretty=TRUE, auto_unbox = TRUE, digits=20)
  
  jsonFile <- tempfile(fileext = ".json")
  
  write(jsonData, jsonFile)
  #write(jsonData, 'test.json')
  
  
  # NOTE
  # It is unlikely that the processing takes over 10 minutes to finish,
  # but if it does, this safeguard needs to be changed
  
  ec <- system2(MATCALL,
          args=c(MCR_PATH, paste0("--infile=", jsonFile[1], "")), timeout=600)
  
  print(paste0("Matlab call finished with code ", ec))
  
  # Error code 124 --> Timeout Happened
  if( ec == 124 ){
    stop(
      "Process Timed out\n
      \n
      HINT: Try increasing memory or CPU's for the operator"
    )
  }
  

  outDf <- as.data.frame( read.csv(outfileTxt) )
  outDf <- outDf %>%
    rename(.ci = colSeq) %>%
    rename(.ri = rowSeq) 
  
  classifierModel <- readBin(outfileMat, "raw", 10e6)
  
  
  
  outDf2 <- data.frame(
    model = "plsda_classifier",
    .base64.serialized.r.model = c(tim::serialise_to_string(classifierModel))
  )
  
  
  # Cleanup
  unlink(outfileMat)
  unlink(outfileTxt)
  unlink(jsonFile)
  
  if(props$DiagnosticPlot != 'None'){
    output_string <- base64enc::base64encode(
      readBin(outfileImg, "raw", file.info(outfileImg)[1, "size"]),
      "txt"
    )
    
  
    output_md <- base64enc::base64encode(charToRaw("# Diagnostic Plot."),"txt")
    
    outTf <- tibble::tibble(
      filename = c("DiagnosticPlot.png", "png"),
      mimetype = c("text/markdown", 'image/png'),
      .content = c(output_md,output_string)
    )
    unlink(outfileImg)
    return( list(outDf, outDf2, outTf) )
  }else{
    return( list(outDf, outDf2) )
  }
}



# =====================
# MAIN OPERATOR CODE
# =====================
ctx = tercenCtx()


colNames  <- ctx$cnames
rowNames  <- ctx$rnames
colorCols <- ctx$colors



df <- ctx$select(c(".ci", ".ri", ".y", colorCols))
  
df[[colorCols[[1]]]] <- as.character( df[[colorCols[[1]]]])

cTable <- ctx$cselect() %>%
  mutate_if(is.numeric, as.character)
rTable <- ctx$rselect() %>%
  mutate_if(is.numeric, as.character)


names.with.dot <- names(cTable)
names.without.dot <- names.with.dot

for( i in seq_along(names.with.dot) ){
  names.without.dot[i] <- gsub("\\.", "_", names.with.dot[i])
  colNames[i] <- gsub("\\.", "_", colNames[i])
}


names(cTable) <- names.without.dot

cTable[[".ci"]] = seq(0, nrow(cTable) - 1)
rTable[[".ri"]] = seq(0, nrow(rTable) - 1)

df = dplyr::left_join(df, cTable, by = ".ci", suffix=c("_col", "_clr") )
df = dplyr::left_join(df, rTable, by = ".ri", suffix=c("_row", "_clr")) 


# Issue #4
# If the same variable is used in color, column and/or row, there is an error
# Because in df those are suffixed, but not in the names.
# Assumes no more than one variable for each
for( i in seq(1, length(colNames))){
  if( colorCols[[1]] == colNames[[i]] ){
    colorCols[[1]] <- paste0( colorCols[[1]], '_clr' )
    colNames[[i]] <- paste0( colNames[[i]], '_col' )
  }
}

for( i in seq(1, length(rowNames))){
  if( colorCols[[1]] == rowNames[[i]] ){
    colorCols[[1]] <- paste0( colorCols[[1]], '_clr' )
    rowNames[[i]] <- paste0( rowNames[[i]], '_row' )
  }
}


props     <- get_operator_props(ctx, imgInfo[1])

#if(props$DebugTest == "Yes"){
 # memReq = 0.5 * 1000 * 1000 * 1000
#  ctx$requestResources(nCpus=1, ram=memReq, ram_per_cpu=memReq)
#}
  

tableList <- df %>%
  classify(props, unlist(colNames), unlist(rowNames), unlist(colorCols) ) 

tbl1 <- tableList[[1]]
tbl2 <- tableList[[2]]

crel <- ctx$cselect() %>%
  mutate(.ci=seq(0,nrow(.)-1)) %>%
  as_relation()

rrel <- ctx$rselect() %>%
  mutate(.ri=seq(0,nrow(.)-1)) %>%
  as_relation()

join1 = tbl1 %>% 
  ctx$addNamespace() %>%
  as_relation() %>%
  left_join_relation(crel, ".ci", crel$rids) %>%
  left_join_relation(rrel, ".ri", rrel$rids) %>%
  as_join_operator(unname(unlist(list(ctx$cnames, ctx$rnames))), 
                   unname(unlist(list(ctx$cnames, ctx$rnames))) )

join2 = tbl2 %>% 
  ctx$addNamespace() %>%
  as_relation() %>%
  as_join_operator(list(), list())



if(props$DiagnosticPlot != 'None'){
  tbl3 <- tableList[[3]]  
  
  join3 = tbl3 %>% 
    ctx$addNamespace() %>%
    as_relation() %>%
    as_join_operator(list(), list())
  
  list(join3, join1, join2) %>%
    save_relation(ctx)
  
  # list(join1) %>%
    # save_relation(ctx)
  
}else{
  list(join1, join2) %>%
    save_relation(ctx)
  
}


