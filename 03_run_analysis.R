#####################################################
## Grant Nguyen
## Purpose: Apply all five statistical/machine learning methods to the dataset
## Evaluate performance using AUC, ROC curves, accuracy, and HL tests


#####################################################
## Set filepaths to code and data
if(Sys.info()[1] =="Windows") {
  home_dir <- "H:/Thesis"
  
  rep_num <- 1      # The repetition number used for the cross-validation (10 repetitions of 10-fold CV), used as a unique seed for each rep
  fold_num <- 6    # The fold number that we should extract from the 10-fold CV to use as a holdout
  tot_folds <- 10   # The total number of folds that we are running (to make sure we specify the correct value for k in createFolds)
  death_wt <- 1    # The weights to use on death for the different methods
  admit_type <- "all" # Whether to run analyses on "all" variables or "admit_only" -- those only available at admission 
} else if (Sys.info()[1] == "Darwin") { # Macintosh
  home_dir <- "/Users/Grant/Desktop/Thesis"
  
  rep_num <- 1
  fold_num <- 10
  tot_folds <- 10
  death_wt <- 10
  admit_type <- "admit_only"
} else if (Sys.info()[1] == "Linux") {
  home_dir <- "/homes/gngu/Thesis"
  
  rep_num <- as.numeric(commandArgs()[4])
  fold_num <- as.numeric(commandArgs()[5])
  tot_folds <- as.numeric(commandArgs()[6])
  death_wt <- as.numeric(commandArgs()[7])
  admit_type <- as.character(commandArgs()[8])
  
  print(commandArgs())
}

ifelse(admit_type=="all",
       load(paste0(home_dir,"/data/02_prepped_data.RData")),
       load(paste0(home_dir,"/data/02_prepped_data_admitonly.RData")))
data_dir <- paste0(home_dir,"/data")
fig_dir <- paste0(data_dir,"/03_figures")
code_dir <- paste0(home_dir,"/mph_thesis_ml")

methods <- c("lr","dt","ct","rf","gb") # The two-letter abbreviations for all of the statistical methods

## Create a common post-fix for standard saving of files with post-fixes by rep/fold/weight combinations
postfix <- paste0(rep_num,"_",fold_num,"_",death_wt,"_",admit_type)

## Add a new R libraries location containing ROCR, xgboost, DiagrammeR, ResourceSelection, Ckmeans.1d.dp, and party packages (not installed on routine cluster)
.libPaths(new = c(.libPaths(),paste0(home_dir,"/../r_libraries")))

#####################################################
## Set Packages
library(data.table) # For easy data management
library(ggplot2) # For graphing
library(caret) # To create folds for each repetition of k-fold cross-validation
library(reshape2) # Standard reshaping requirements

## Import analysis functions
source(paste0(code_dir,"/analysis_functions.R"))

## Set seed for reproducibility, toggled by repetition number
## Keep the same rep/fold splits across death_wt and admission loops
set.seed(paste0(rep_num,"99",fold_num,"99"))

## Create function to easily add id variables for each loop (used to format output datasets)
add_loopvars <- function(data) {
  data[,fold:=fold_num]
  data[,rep:=rep_num]
  data[,d_wt:=death_wt]
  data[,admit:=admit_type]
  return(data)
}

####################################################
## Format data

## Create test and train datasets
data_indices <- master_data[,as.factor(death)]

## Create holdouts, attempting to balance class distribution within splits
## The indices must be factors in order to be balanced appropriately
holdouts <- createFolds(data_indices,k=tot_folds,list=T,returnTrain=F)[[fold_num]]

train_data <- master_data[-holdouts]
test_data <- master_data[holdouts]

## First, resample with replacement to up-weight deaths by the factor specified (only on training data, NOT on test dataset)
if(death_wt != 1) {
  death_data <- train_data[death=="Yes",]
  boot_indic <- sample(1:nrow(death_data), (nrow(death_data) * (death_wt-1)), replace=T)
  boot_data <- death_data[boot_indic,]
  train_data <- rbindlist(list(train_data,boot_data),use.names=T)
}


####################################################
## Run analyses, extract pertinent information

## Logistic Regression
  system.time(lr_results <- run_logistic(data=train_data,formula=test_formula))
  lr_fit <- lr_results[1][[1]]
  lr_preds <- lr_results[2][[1]]
  lr_coefs <- lr_results[3][[1]]
  
  lr_coefs[,d_wt:=death_wt]
  lr_coefs[,admit:=admit_type]

##  Aborted test of stepwise logistic regression (computation time too long)
#   test_vars <- c(cv_vars,dx_vars[grepl("admit",dx_vars)])
#   system.time(step <- step(lr_fit,trace=1,direction="backward"))
#   test_formula <- as.formula(paste("death~",paste(test_vars,collapse="+")))
#   lr_fit <- glm(test_formula,data=train_data,family=binomial(link="logit"))
#   system.time(step <- step(lr_fit,trace=1,direction="backward"))           


## Decision Tree
  system.time(dt_results <- run_dtree(data=train_data,formula=test_formula))
  dt_fit <- dt_results[1][[1]]
  dt_preds <- dt_results[2][[1]][,2]


## Conditional Inference Tree
  system.time(ct_results <- run_ctree(data=train_data,formula=test_formula))

  ct_fit <- ct_results[1][[1]]
  ct_preds <- ct_results[2][[1]][,2]

## Run a random forest 
## Roughly 35 minutes for 100 trees -> ~3 hours for 500 trees
if(Sys.info()[1] =="Linux") {
  system.time(rf_results <- run_par_rf(data=train_data,formula=test_formula))
} else if(Sys.info()[1] =="Windows")  {
  system.time(rf_results <- run_rf(data=train_data,formula=test_formula,num_trees=50))
}
  rf_fit <- rf_results[1][[1]]
  rf_preds <- rf_results[2][[1]][,2]

## Gradient Boosting Machines
## Roughly 20 seconds for 5 rounds and 3 folds
  system.time(gb_results <- run_boost(tr_data=train_data,te_data=test_data))
  gb_fit <- gb_results[1][[1]]
  gb_preds <- gb_results[2][[1]]
  gb_imp <- gb_results[3][[1]]


####################################################
## Plot results
  ## Calculate ROC curves
  test_data[,death_test:=as.numeric(death)-1] # Factor var is 1 for alive, 2 for dead -- convert to 0 for alive, 1 for dead
  
  library(ROCR)

  ## First, save the ROC curves for use in plotting compiled 
  extract_roc <- function(pred_type) {
    pred <- prediction(get(paste0(pred_type,"_preds")),test_data[,death_test])
    perf <- performance(pred,"tpr","fpr")
    roc_results <- data.table(fpr=unlist(perf@x.values),tpr=unlist(perf@y.values),pred_method=pred_type)
    return(roc_results)
  }
  roc_results <- rbindlist(lapply(methods,extract_roc))
  roc_results <- add_loopvars(roc_results)
  write.csv(roc_results,paste0(data_dir,"/03_perf/auc/roc_",postfix,".csv"),row.names=F) 


## Save xgboost ensemble tree
## Note: Output is stored in html format, so it can only be run locally, and exported via RStudio viewer
#   library(stringr)
#   library(DiagrammeR)
#   source(paste0(code_dir,"/xgb_funcs.R")) # Import edited xgboost.multi.tree graphing function
# 
#   xg_tree <- xgb.plot.multi.trees(model = gb_fit, features.keep = 3) ## Need to add feature names
#   save(xg_tree,file=paste0(fig_dir,"/gb_",postfix,".RData"))
  
  ## Calculate AUC
  calc_auc <- function(pred_method) {
    library(ROCR)
    pred <- prediction(get(paste0(pred_method,"_preds")),test_data[,death_test])
    auc_perf <- performance(pred,measure="auc")
    auc <- unlist(auc_perf@y.values)
    auc_dt <- data.table(pred_method,auc)
    return(auc_dt)
  }

  auc_results <- rbindlist(lapply(methods,calc_auc))

  ## Calculate Accuracy at various cutoffs
  ## Cutoffs are the probability of event (death) predicted by each method
  calc_accuracy <- function(pred_type) {
    library(ROCR)
    get_accuracy <- function(x) {
      acc_perf@y.values[[1]][max(which(acc_perf@x.values[[1]] >= x))]
    }
    pred <- prediction(get(paste0(pred_type,"_preds")),test_data[,death_test])
    acc_perf <- performance(pred,measure="acc")

    ## This gives the accuracy of the method at different cutoffs of predicted probability
    test_probs <- c(seq(.1,.5,.1),.75,.9)
    results <- unlist(do.call(rbind,lapply(test_probs,get_accuracy)))
    acc_dt <- data.table(cbind(
      pred_method=rep(pred_type,length(test_probs)),
      pred_prob=test_probs,
      results))
    setnames(acc_dt,"V3","accuracy") # For some reason, renaming accuracy within cbind doesn't work
    return(acc_dt)
  }

  acc_results <- rbindlist(lapply(methods,calc_accuracy))

  ## Calculate Hosmer-Lemeshow statistic
  ## Create function that takes in pred_method and returns a data.table with the statistic and p_value
  calc_hl <- function(pred_type) {
    library(ResourceSelection)
    preds <- get(paste0(pred_type,"_preds"))
    if(length(unique(preds)) != 1) {
      hl_results <- hoslem.test(test_data[,death_test],preds,g=15)
      results <- data.table(pred_method=pred_type,stat=hl_results$statistic,p=hl_results$p.value)
    } else {
      results <- data.table(pred_method=pred_type,stat=NA,p=0)
    }
    return(results)  
  }

  hl_compiled <- rbindlist(lapply(methods,calc_hl))

  calc_hl_bins <- function(pred_type) {
    library(ResourceSelection)
    preds <- get(paste0(pred_type,"_preds"))
    if(length(unique(preds)) != 1) {
      hl_results <- hoslem.test(test_data[,death_test],preds,g=15)
      bin_results <- data.frame(cbind(hl_results$observed,hl_results$expected))
      bin_results$pred_method <- paste0(pred_type)
      setDT(bin_results,keep.rownames=T)
      setnames(bin_results,"rn","prob_range")
    } else {
      bin_results <- data.table(prob_range="0,1",pred_method=paste0(pred_type),y0=NA,y1=NA,yhat0=NA,yhat1=NA)
    }
    setcolorder(bin_results,c("prob_range","pred_method","y0","y1","yhat0","yhat1"))
    return(bin_results)
  }
  hl_bins <- rbindlist(lapply(methods,calc_hl_bins))


####################################################
## Export data
## Check size of all objects
  for (thing in ls()) { message(thing); print(object.size(get(thing)), units='auto') }

## Export variables included in trees and variable importances (RF and GB)
  var_list <- c()
  traverse <- function(treenode){
    if(treenode$terminal){
      bas=paste("Current node is terminal node with",treenode$nodeID,'prediction',treenode$prediction)
      print(bas)
      return(0)
    } else {
      bas=paste("Current node",treenode$nodeID,"Split var. ID:",treenode$psplit$variableName,"split value:",treenode$psplit$splitpoint,'prediction',treenode$prediction)
      print(bas)
      var_list <<- c(var_list,treenode$psplit$variableName) ## Edit the global var_list variable (can't do it inside and return var_list because of recursion)
    }
    traverse(treenode$left)
    traverse(treenode$right)
  }

  traverse(ct_fit@tree)
  ct_list <- data.table(var_name=var_list,include=1,pred_method="ct")

  lr_list <- coef(summary(lr_fit))[,4]
  lr_list <- data.frame(as.list(lr_list))
  ## Reshape long the lr_list here
  library(reshape2)
  lr_list <- melt(lr_list)
  lr_list <- lr_list[lr_list$value < .05,] 
  lr_list <- data.table(var_name=as.character(lr_list$variable),include=1,pred_method="lr")
  
  include_list <- rbindlist(list(ct_list,lr_list),use.names=T)
  include_list <- add_loopvars(include_list)

  ## Data.table with pred_method, imp_type (gini or other), measure
  pull_imp <- function(pred_type) {
    if(grepl("dt",pred_type) & !is.null(get(paste0(pred_type,"_fit"))$variable.importance)) {
      imp <- data.frame(measure=get(paste0(pred_type,"_fit"))$variable.importance)
      setDT(imp,keep.rownames=T)
      setnames(imp,c("rn"),c("var_name"))
      
      imp[,imp_type:="accuracy"]
    } else if(grepl("dt",pred_type) & is.null(get(paste0(pred_type,"_fit"))$variable.importance)) {
      imp <- data.table(var_name=NA,imp_type=NA,measure=NA)
    } else if(grepl("rf",pred_type)) {
      imp <- data.frame(get(paste0(pred_type,"_fit"))$importance)
      setDT(imp, keep.rownames=T)
      setnames(imp,c("rn","MeanDecreaseAccuracy","MeanDecreaseGini"),c("var_name","accuracy","gini"))
      imp[,c("Yes","No"):=NULL]
      imp <- melt(imp,id.vars="var_name",variable.name="imp_type",value.name="measure",variable.factor=F)
    } else if(grepl("gb",pred_type)) {
      imp <- get(paste0(pred_type,"_imp"))[,list(Feature,Gain)]
      setnames(imp,c("Feature","Gain"),c("var_name","measure"))
      imp[,imp_type:="accuracy"]
    } else if(grepl("cg",pred_type)) {
      imp <- get(paste0(pred_type,"_imp"))
      imp[,imp_type:="accuracy"]
    }
    imp[,pred_method:=pred_type]
    setcolorder(imp,c("var_name","imp_type","measure","pred_method"))
    return(imp)
  }
  imp_methods <- methods[!methods %in% c("ct","lr")]
  importances <- rbindlist(lapply(imp_methods,pull_imp),use.names=T)
  importances <- add_loopvars(importances)
  
  write.csv(include_list,paste0(data_dir,"/03_perf/var_imp/include_vars_",postfix,".csv"),row.names=F)
  write.csv(importances,paste0(data_dir,"/03_perf/var_imp/imp_",postfix,".csv"),row.names=F)
  write.csv(lr_coefs,paste0(data_dir,"/03_perf/var_imp/lr_",postfix,".csv"),row.names=F)

## Export csv for AUC, accuracy, and hosmer-lemeshow, along with fold# and rep#
  auc_results <- add_loopvars(auc_results)
  write.csv(auc_results,paste0(data_dir,"/03_perf/auc/auc_",postfix,".csv"),row.names=F)

  acc_results <- add_loopvars(acc_results)
  write.csv(acc_results,paste0(data_dir,"/03_perf/acc/acc_",postfix,".csv"),row.names=F)

  hl_compiled <- add_loopvars(hl_compiled)
  write.csv(hl_compiled,paste0(data_dir,"/03_perf/hl/hl_",postfix,".csv"),row.names=F)
    
  hl_bins <- add_loopvars(hl_bins)
  write.csv(hl_bins,paste0(data_dir,"/03_perf/hl/hl_bins_",postfix,".csv"),row.names=F)


